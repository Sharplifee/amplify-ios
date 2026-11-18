import Foundation
import UserNotifications
import AVFoundation

// MARK: - What Scribbly® notifies about

/// Each kind of alert has its own on/off, tone and vibration, like iOS
/// Sounds & Haptics (Ringtone · Text Tone · New Mail …).
enum NotifyKind: String, CaseIterable, Identifiable, Codable {
    case transcriptReady, recordingSaved, needsAttention, batchFinished, watchMemo
    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcriptReady: return "Transcript Ready"
        case .recordingSaved:  return "Recording Uploaded"
        case .needsAttention:  return "Needs Attention"
        case .batchFinished:   return "Batch Finished"
        case .watchMemo:       return "Apple Watch Memo"
        }
    }
    var detail: String {
        switch self {
        case .transcriptReady: return "A recording, video or file is transcribed, summarized and in your library."
        case .recordingSaved:  return "A recording left this iPhone and is on the Legacy Prism server."
        case .needsAttention:  return "Something didn't work — no speech found, or a job failed."
        case .batchFinished:   return "A channel, playlist or set of links finished fetching."
        case .watchMemo:       return "A memo recorded on your Apple Watch arrived on this iPhone."
        }
    }
    var icon: String {
        switch self {
        case .transcriptReady: return "text.bubble.fill"
        case .recordingSaved:  return "icloud.and.arrow.up.fill"
        case .needsAttention:  return "exclamationmark.triangle.fill"
        case .batchFinished:   return "square.stack.fill"
        case .watchMemo:       return "applewatch"
        }
    }
    var defaultTone: String {
        switch self {
        case .transcriptReady: return "scribbly"
        case .recordingSaved:  return "ripple"
        case .needsAttention:  return "glass"
        case .batchFinished:   return "marimba"
        case .watchMemo:       return "pebble"
        }
    }
    var defaultHaptic: String {
        switch self {
        case .transcriptReady: return "synced"
        case .recordingSaved:  return "pulse"
        case .needsAttention:  return "heartbeat"
        case .batchFinished:   return "synced"
        case .watchMemo:       return "synced"
        }
    }
    /// Notification Center groups each kind into its own stack.
    var threadID: String { "scribbly.\(rawValue)" }
}

// MARK: - Tones

struct Tone: Identifiable, Hashable {
    let id: String
    let name: String
    /// Seconds where each note starts — "Synchronized" vibration taps on these.
    let onsets: [Double]
}

struct CustomTone: Codable, Identifiable, Hashable {
    let id: String      // "custom:<uuid>"
    var name: String
    var file: String    // the playable tone, in Library/Sounds
    /// The untouched original, kept in the Scribbly folder (Files › On My
    /// iPhone › Scribbly › Tones) so the tone can be re-trimmed any time.
    var source: String? = nil
    var start: Double? = nil
    var end: Double? = nil
    var duration: Double? = nil
}

enum ToneLibrary {
    static let systemID = "system"
    static let noneID = "none"

    /// The three Scribbly® defaults, shown first.
    static let defaults: [Tone] = [
        Tone(id: "scribbly", name: "Legacy Prism", onsets: [0, 0.11, 0.22]),
        Tone(id: "ripple", name: "Ripple", onsets: [0, 0.07, 0.14, 0.21, 0.28, 0.35]),
        Tone(id: "glass", name: "Glass", onsets: [0, 0.09]),
    ]
    /// Every other bundled tone (synthesized for Scribbly®, all under 3 s).
    static let alerts: [Tone] = [
        Tone(id: "aurora", name: "Aurora", onsets: [0, 0.16, 0.32, 0.48]),
        Tone(id: "beacon", name: "Beacon", onsets: [0, 0.32, 0.64]),
        Tone(id: "bloom", name: "Bloom", onsets: [0, 0.05, 0.1, 0.15, 0.2]),
        Tone(id: "breeze", name: "Breeze", onsets: [0, 0.12, 0.24]),
        Tone(id: "cascade", name: "Cascade", onsets: [0, 0.06, 0.12, 0.18, 0.24, 0.3, 0.36, 0.42]),
        Tone(id: "chord", name: "Chord", onsets: [0]),
        Tone(id: "crystal", name: "Crystal", onsets: [0, 0.08, 0.16]),
        Tone(id: "echo", name: "Echo", onsets: [0, 0.22, 0.44, 0.66, 0.88]),
        Tone(id: "ember", name: "Ember", onsets: [0, 0.14]),
        Tone(id: "halo", name: "Halo", onsets: [0]),
        Tone(id: "lumen", name: "Lumen", onsets: [0, 0.1]),
        Tone(id: "marimba", name: "Marimba", onsets: [0, 0.13, 0.26, 0.39]),
        Tone(id: "nova", name: "Nova", onsets: [0, 0.045, 0.09, 0.135, 0.18, 0.225]),
        Tone(id: "pebble", name: "Pebble", onsets: [0, 0.12]),
        Tone(id: "pulse", name: "Pulse", onsets: [0, 0.14, 0.28, 0.42]),
        Tone(id: "quill", name: "Quill", onsets: [0, 0.07, 0.14, 0.21]),
        Tone(id: "signal", name: "Signal", onsets: [0, 0.18, 0.36, 0.54]),
        Tone(id: "spark", name: "Spark", onsets: [0, 0.05, 0.1]),
        Tone(id: "tide", name: "Tide", onsets: [0, 0.2, 0.4, 0.6]),
        Tone(id: "whisper", name: "Whisper", onsets: [0, 0.15]),
    ]
    static var bundled: [Tone] { defaults + alerts }

    // Custom tones live in Library/Sounds — the one folder iOS reads
    // notification sounds from besides the app bundle.
    static var soundsDir: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let d = lib.appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static let customKey = "notify.customTones"
    static var customs: [CustomTone] {
        get {
            guard let d = UserDefaults.standard.data(forKey: customKey),
                  let v = try? JSONDecoder().decode([CustomTone].self, from: d) else { return [] }
            return v.filter { FileManager.default.fileExists(atPath: soundsDir.appendingPathComponent($0.file).path) }
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: customKey) }
    }

    static func name(_ id: String) -> String {
        if id == systemID { return "iOS Default" }
        if id == noneID { return "None" }
        if let t = bundled.first(where: { $0.id == id }) { return t.name }
        if let c = customs.first(where: { $0.id == id }) { return c.name }
        return "Legacy Prism"
    }
    static func onsets(_ id: String) -> [Double] {
        if let t = bundled.first(where: { $0.id == id }) { return t.onsets }
        return [0, 0.15]
    }
    static func fileName(_ id: String) -> String? {
        if bundled.contains(where: { $0.id == id }) { return "scribbly-\(id).caf" }
        return customs.first(where: { $0.id == id })?.file
    }
    static func url(_ id: String) -> URL? {
        if bundled.contains(where: { $0.id == id }) {
            return Bundle.main.url(forResource: "scribbly-\(id)", withExtension: "caf")
        }
        if let c = customs.first(where: { $0.id == id }) { return soundsDir.appendingPathComponent(c.file) }
        return nil
    }
    /// What the notification itself plays. nil = silent.
    static func sound(_ id: String) -> UNNotificationSound? {
        if id == noneID { return nil }
        if id == systemID { return .default }
        guard let f = fileName(id) else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(f))
    }

    /// The Scribbly folder in the Files app (On My iPhone › Scribbly › Tones).
    static var originalsDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("Tones", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static let maxSeconds = 29.0   // iOS plays the default sound for anything 30 s or longer

    /// Imports any audio file as a tone: the original is copied into the
    /// Scribbly folder, and the first 29 s become the playable tone (16-bit PCM
    /// CAF in Library/Sounds — a format iOS plays for notifications).
    static func importTone(from src: URL, name: String) throws -> CustomTone {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let uuid = UUID().uuidString
        let ext = src.pathExtension.isEmpty ? "m4a" : src.pathExtension
        let original = "\(uuid.prefix(8))-\(src.deletingPathExtension().lastPathComponent).\(ext)"
        let dst = originalsDir.appendingPathComponent(original)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        let dur = (try? AVAudioFile(forReading: dst)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? maxSeconds
        var tone = CustomTone(id: "custom:\(uuid)", name: name.isEmpty ? "Custom Tone" : name, file: "",
                              source: original, start: 0, end: min(dur, maxSeconds), duration: dur)
        tone.file = try render(tone)
        customs = customs + [tone]
        return tone
    }

    /// Writes the [start, end] slice of a tone's original as a new CAF and
    /// returns its file name (a fresh name each time, so iOS never plays a
    /// cached older cut).
    static func render(_ t: CustomTone) throws -> String {
        guard let srcName = t.source else { throw CocoaError(.fileNoSuchFile) }
        let input = try AVAudioFile(forReading: originalsDir.appendingPathComponent(srcName))
        let fmt = input.processingFormat
        let start = max(0, t.start ?? 0)
        let end = min(t.end ?? maxSeconds, start + maxSeconds, Double(input.length) / fmt.sampleRate)
        let file = "custom-\(UUID().uuidString).caf"
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: min(fmt.channelCount, 2),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let out = try AVAudioFile(forWriting: soundsDir.appendingPathComponent(file), settings: settings,
                                  commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        input.framePosition = AVAudioFramePosition(start * fmt.sampleRate)
        var remaining = AVAudioFramePosition((end - start) * fmt.sampleRate)
        while remaining > 0, input.framePosition < input.length {
            let want = AVAudioFrameCount(min(8192, remaining))
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: want) else { break }
            try input.read(into: buf, frameCount: want)
            if buf.frameLength == 0 { break }
            try out.write(from: buf)
            remaining -= AVAudioFramePosition(buf.frameLength)
        }
        return file
    }

    /// Saves a new trim: renders it, swaps the tone over, deletes the old cut.
    static func retrim(_ id: String, start: Double, end: Double) throws {
        var all = customs
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        var t = all[i]
        let old = t.file
        t.start = start; t.end = end
        t.file = try render(t)
        all[i] = t
        customs = all
        try? FileManager.default.removeItem(at: soundsDir.appendingPathComponent(old))
    }

    /// Loudness envelope of a tone's whole original (0…1, `bins` bars) for the
    /// trimmer — read in small chunks so a long song never loads into memory.
    static func waveform(_ id: String, bins: Int = 90) -> [Float] {
        guard let t = customs.first(where: { $0.id == id }), let srcName = t.source,
              let f = try? AVAudioFile(forReading: originalsDir.appendingPathComponent(srcName)),
              f.length > 0 else { return [] }
        let per = max(1, Int(f.length) / bins)
        var out: [Float] = []
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 16_384) else { return [] }
        var peak: Float = 0
        var inBin = 0
        while f.framePosition < f.length, out.count < bins {
            buf.frameLength = 0
            guard (try? f.read(into: buf, frameCount: 16_384)) != nil, buf.frameLength > 0,
                  let ch = buf.floatChannelData?[0] else { break }
            // Sample every 32nd frame — plenty for bars, far cheaper.
            var k = 0
            let n = Int(buf.frameLength)
            while k < n {
                peak = max(peak, abs(ch[k]))
                inBin += 32
                if inBin >= per { out.append(peak); peak = 0; inBin = 0 }
                k += 32
            }
        }
        if out.count < bins, peak > 0 { out.append(peak) }
        let top = max(out.max() ?? 1, 0.0001)
        return out.map { $0 / top }
    }

    static func deleteCustom(_ id: String) {
        guard let c = customs.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: soundsDir.appendingPathComponent(c.file))
        if let src = c.source { try? FileManager.default.removeItem(at: originalsDir.appendingPathComponent(src)) }
        customs = customs.filter { $0.id != id }
    }
}
