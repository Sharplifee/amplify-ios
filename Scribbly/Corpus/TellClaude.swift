import SwiftUI
import AVFoundation

/// "Tell Claude": notes about the app itself — typed or spoken while you move
/// around Scribbly — that go to a Claude session to be built, NOT into your
/// library. The voice server transcribes spoken notes and stores them in
/// scribbly_claude_notes; Claude picks them up, makes the change, ships the
/// build and writes its reply back here.
@MainActor
final class TellClaude: ObservableObject {
    static let shared = TellClaude()

    struct Note: Decodable, Identifiable {
        let id: Int
        let created_at: String
        let source: String
        let text: String?
        let audio_seconds: Int?
        let status: String
        let reply: String?
        let session_url: String?
        let error: String?
    }

    @Published var notes: [Note] = []
    @Published var draft = ""
    @Published var sending = false
    @Published var message: String?
    @Published private(set) var recording = false
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var timer: Timer?
    private var fileURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("tell-claude.m4a") }

    private var base: String {
        var u = CorpusAPI.voiceIngestURL
        if let r = u.range(of: "/upload", options: .backwards) { u = String(u[..<r.lowerBound]) }
        return u
    }

    // MARK: Notes list

    func load() async {
        guard let url = URL(string: base + "/claude-notes") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 20
        if let t = AuthTokens.access { req.setValue(t, forHTTPHeaderField: "x-auth") }
        struct R: Decodable { let notes: [Note] }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(R.self, from: data) else { return }
        notes = r.notes
    }

    // MARK: Typed note

    func sendText() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true; defer { sending = false }
        var req = URLRequest(url: URL(string: base + "/claude-note")!)
        req.httpMethod = "POST"; req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = AuthTokens.access { req.setValue(t, forHTTPHeaderField: "x-auth") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        if await post(req) { draft = ""; EventLog.shared.log("tellclaude.sent", ["kind": "text", "chars": text.count]) }
    }

    // MARK: Spoken note (keeps going while you move around the app)

    var canRecord: Bool { Recorder.shared.state == .idle }

    func toggleRecording() { recording ? stopAndSend() : start() }

    func start() {
        guard !recording else { return }
        guard canRecord else { message = "Finish the recording in progress first."; return }
        Recorder.shared.requestPermission { ok in
            Task { @MainActor in
                guard ok else { self.message = "Legacy Prism needs microphone access for spoken notes."; return }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .spokenAudio, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try s.setActive(true)
            try? FileManager.default.removeItem(at: fileURL)
            let r = try AVAudioRecorder(url: fileURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48000])
            guard r.record() else { message = "Couldn't start the microphone."; return }
            recorder = r; recording = true; startedAt = Date(); elapsed = 0; message = nil
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let s = self.startedAt else { return }
                    self.elapsed = Date().timeIntervalSince(s)
                }
            }
            EventLog.shared.log("tellclaude.record_start", [:])
        } catch {
            message = "Couldn't start the microphone: \(error.localizedDescription)"
            EventLog.shared.log("tellclaude.record_fail", ["error": error.localizedDescription])
        }
    }

    func cancel() {
        recorder?.stop(); recorder = nil; timer?.invalidate(); timer = nil
        recording = false; elapsed = 0
        try? FileManager.default.removeItem(at: fileURL)
        EventLog.shared.log("tellclaude.record_cancel", [:])
    }

    func stopAndSend() {
        guard recording else { return }
        recorder?.stop(); recorder = nil; timer?.invalidate(); timer = nil
        recording = false
        let secs = elapsed
        if Recorder.shared.state == .idle { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        guard secs >= 1, let data = try? Data(contentsOf: fileURL) else { message = "That was too short to send."; return }
        Task {
            sending = true; defer { sending = false }
            var req = URLRequest(url: URL(string: base + "/claude-note")!)
            req.httpMethod = "POST"; req.timeoutInterval = 120
            req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
            req.setValue("m4a", forHTTPHeaderField: "x-ext")
            if let t = AuthTokens.access { req.setValue(t, forHTTPHeaderField: "x-auth") }
            req.httpBody = data
            if await post(req) {
                try? FileManager.default.removeItem(at: fileURL)
                EventLog.shared.log("tellclaude.sent", ["kind": "voice", "secs": Int(secs)])
                // Transcription takes a few seconds on the cloud computer.
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await load()
            }
        }
    }

    private func post(_ req: URLRequest) async -> Bool {
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                let err = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String
                message = code == 403 ? "Tell Claude is only on for the library owner's account." : "Didn't send: \(err ?? "HTTP \(code)")"
                EventLog.shared.log("tellclaude.send_fail", ["code": code, "error": err ?? ""])
                return false
            }
            message = "Sent. Claude picks it up, makes the change and replies here."
            await load()
            return true
        } catch {
            message = "Didn't send: \(error.localizedDescription). Your note is still here — try again."
            EventLog.shared.log("tellclaude.send_fail", ["error": error.localizedDescription])
            return false
        }
    }

    static func clock(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
}

// MARK: - Page

struct TellClaudeSection: View {
    @ObservedObject private var tc = TellClaude.shared
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PageHeader(title: "Tell Claude", subtitle: "Changes you want made to Legacy Prism",
                           back: { BottomChrome.shared.moreSub = nil })
                VStack(alignment: .leading, spacing: 10) {
                    Text("SPEAK").sectionHead()
                    Button { tc.toggleRecording() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: tc.recording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(tc.recording ? P.bg : P.ink)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(tc.recording ? P.accent : P.surface2))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tc.recording ? "Recording · \(TellClaude.clock(tc.elapsed))" : "Record a note")
                                    .font(.geist(size: 15.5, weight: .semibold)).foregroundColor(P.ink)
                                Text(tc.recording ? "Move around the app and keep talking. Tap Stop to send."
                                                  : "Walk through the app and say what to change. It never goes in your library.")
                                    .font(.geist(size: 12.5)).foregroundColor(P.textSec).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(tc.recording ? P.accent.opacity(0.7) : P.border))
                    }
                    .buttonStyle(.plain)

                    Text("TYPE").sectionHead().padding(.top, 8)
                    VStack(alignment: .trailing, spacing: 10) {
                        TextField("What should change?", text: $tc.draft, axis: .vertical)
                            .lineLimit(3...10).focused($typing)
                            .font(.geist(size: 15)).foregroundColor(P.ink)
                        Button { typing = false; Task { await tc.sendText() } } label: {
                            Text(tc.sending ? "Sending…" : "Send to Claude")
                                .font(.geist(size: 14, weight: .semibold)).foregroundColor(P.bg)
                                .padding(.horizontal, 16).frame(height: 36)
                                .background(Capsule().fill(tc.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? P.textDim : P.accent))
                        }
                        .buttonStyle(.plain)
                        .disabled(tc.sending || tc.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(14)
                    .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(P.border))

                    if let m = tc.message {
                        Text(m).font(.geist(size: 13)).foregroundColor(P.textSec)
                    }

                    if !tc.notes.isEmpty {
                        Text("SENT").sectionHead().padding(.top, 8)
                        ForEach(tc.notes) { n in NoteRow(n: n) }
                    }
                }
                .padding(16)
            }
        }
        .task {
            while !Task.isCancelled {
                await tc.load()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private struct NoteRow: View {
        let n: TellClaude.Note
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: n.source == "voice" ? "waveform" : "text.alignleft").font(.system(size: 11))
                    Text(Self.when(n.created_at)).font(.geist(size: 11.5, design: .monospaced))
                    Spacer()
                    Text(Self.label(n.status)).font(.geist(size: 11.5, weight: .semibold))
                        .foregroundColor(n.status == "done" ? P.good : n.status == "failed" ? P.danger : P.accent)
                }
                .foregroundColor(P.textDim)
                Text(n.text ?? (n.status == "transcribing" ? "Transcribing…" : ""))
                    .font(.geist(size: 14)).foregroundColor(P.ink).lineLimit(6)
                if let r = n.reply, !r.isEmpty {
                    Text(r).font(.geist(size: 13.5)).foregroundColor(P.textSec)
                        .padding(.top, 2).fixedSize(horizontal: false, vertical: true)
                }
                if let e = n.error, !e.isEmpty, n.status == "failed" {
                    Text(e).font(.geist(size: 12.5)).foregroundColor(P.danger)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(P.border))
        }
        static func label(_ s: String) -> String {
            switch s {
            case "transcribing": return "Transcribing"
            case "new": return "Waiting for Claude"
            case "working": return "Claude is on it"
            case "done": return "Done"
            case "failed": return "Didn't work"
            default: return s.capitalized
            }
        }
        static func when(_ iso: String) -> String {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? Date()
            let o = DateFormatter(); o.dateFormat = "MMM d, h:mm a"; o.timeZone = .current
            return o.string(from: d)
        }
    }
}

/// While a spoken note is recording, a small pill floats over every page so
/// you can keep moving around the app and stop it from anywhere.
struct TellClaudePill: View {
    @ObservedObject private var tc = TellClaude.shared
    var body: some View {
        if tc.recording {
            HStack(spacing: 10) {
                Circle().fill(P.accent).frame(width: 8, height: 8)
                Text("Note to Claude · \(TellClaude.clock(tc.elapsed))")
                    .font(.geist(size: 13, weight: .semibold, design: .monospaced)).monospacedDigit()
                    .foregroundColor(P.ink)
                Button { tc.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundColor(P.textSec)
                        .frame(width: 28, height: 28)
                }.buttonStyle(.plain).accessibilityLabel("Discard note")
                Button { tc.stopAndSend() } label: {
                    Text("Send").font(.geist(size: 13, weight: .semibold)).foregroundColor(P.bg)
                        .padding(.horizontal, 12).frame(height: 28).background(Capsule().fill(P.accent))
                }.buttonStyle(.plain)
            }
            .padding(.leading, 14).padding(.trailing, 6).frame(height: 40)
            .background(Capsule().fill(P.surface2))
            .overlay(Capsule().stroke(P.accent.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
