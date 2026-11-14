import SwiftUI

/// The bottom bar: four glass tabs with the Record button as the largest
/// element, a 76pt disc standing proud of the bar (per Connor's reference).
/// Replaces the system tab bar so the mic can overflow it.
///
/// While a recording is live (recording / paused / finishing) the tabs STAY
/// usable — you can move between pages while you talk. A slim recorder strip
/// grows out of the top of the same glass shape (one piece, not a second bar):
/// timer · live wave · Discard · Pause · ✓ Finish, on dark monochrome glass. The record disc steps aside so the four tabs
/// spread out. Upload shows its live percentage in the same strip, then the
/// strip folds away. Server processing afterwards rides along as a thin line
/// plus a ring and % badge on the record disc.
struct GlassTabBar: View {
    @Binding var selection: LibraryScreen.Section
    var onRecord: () -> Void

    private let left: [LibraryScreen.Section]  = [.home, .library]
    private let right: [LibraryScreen.Section] = [.groups, .more]

    @ObservedObject private var rec = Recorder.shared
    @ObservedObject private var up = Uploader.shared
    @ObservedObject private var status = StatusWatcher.shared
    @ObservedObject private var notify = NotifySettings.shared
    @State private var recordTaps = 0
    @State private var lastFinishAt = Date.distantPast
    @State private var finishTaps = 0
    @State private var showDiscardConfirm = false
    @Namespace private var glassNS

    /// What the bar is right now.
    enum Mode: Equatable { case tabs, recorder, upload }

    private var mode: Mode {
        if rec.state != .idle { return .recorder }
        if up.isUploading { return .upload }
        return .tabs
    }

    private static let disc: CGFloat = 76
    private static let morph = Animation.spring(response: 0.42, dampingFraction: 0.86)

    var body: some View {
        let m = mode
        return VStack(spacing: 0) {
            if m == .recorder {
                recorderStrip
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if m == .upload {
                uploadStrip
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            tabsRow(withDisc: m == .tabs)
                .padding(.horizontal, 6).padding(.vertical, 6)
                .overlay(alignment: .center) {
                    if m == .tabs { centreDisc(m).transition(.scale(scale: 0.6).combined(with: .opacity)) }
                }
        }
        .fixedSize(horizontal: false, vertical: true)
        // Monochrome while the recorder/upload strip is showing: dark glass, no colour cast.
        .sinkyGlass(RoundedRectangle(cornerRadius: 31, style: .continuous),
                    tint: m == .tabs ? nil : Color.black.opacity(0.55))
        .padding(.top, 6)
        // Sit low, where a tab bar belongs: reach into the home-indicator
        // zone instead of floating above it.
        .padding(.horizontal, 16).padding(.bottom, -12)
        .animation(Self.morph, value: m)
        .sinkyHaptic(selection)
        .sinkyHaptic(m)
        .alert("Discard this recording?", isPresented: $showDiscardConfirm) {
            Button("Keep recording", role: .cancel) {}
            Button("Discard", role: .destructive) { rec.discard() }
        } message: { Text("The audio will be deleted and cannot be recovered.") }
    }

    private func tabsRow(withDisc: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(left) { tab(for: $0) }
            if withDisc { Spacer().frame(width: Self.disc) }   // room under the record button
            ForEach(right) { tab(for: $0) }
        }
    }

    // MARK: Recorder strip (recording / paused / finishing)

    private var timeString: String {
        let t = Int(rec.elapsed)
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) }
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    private var statusText: String {
        if rec.interrupted { return "Interrupted" }
        switch rec.state {
        case .recording: return rec.appendTo == nil ? "Recording" : "Adding"
        case .paused:    return "Paused"
        case .finishing: return "Saving"
        case .idle:      return ""
        }
    }

    private var statusColor: Color {
        if rec.interrupted { return .orange }
        return rec.state == .recording ? P.accent : P.textDim
    }

    /// Timer · live wave · then the controls in the order you use them:
    /// Discard, Pause/Resume, ✓ Finish. The live wave is the "it's recording"
    /// signal, so there's no separate dot.
    private var recorderStrip: some View {
        let busy = rec.state == .finishing
        let recording = rec.state == .recording
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(timeString)
                    .font(.geist(size: 16, weight: .medium, design: .monospaced)).monospacedDigit()
                    .foregroundColor(P.ink).lineLimit(1).minimumScaleFactor(0.7)
                Text(statusText).monoLabel(8.5, color: statusColor).lineLimit(1)
            }
            .fixedSize()
            .padding(.leading, 6)
            .accessibilityElement(children: .combine)
            WaveBars(level: rec.level, active: recording).frame(height: 22)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            // 1 · Discard — asks first
            Button { showDiscardConfirm = true } label: {
                roundIcon("trash", tint: P.danger.opacity(0.9), size: 38)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel("Discard recording")
            // 2 · Pause / Resume
            Button { recording ? rec.pause() : rec.resume() } label: {
                roundIcon(recording ? "pause.fill" : "play.fill", tint: P.ink, size: 38)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel(recording ? "Pause" : "Resume")
            // 3 · Finish and save (primary)
            Button {
                guard rec.state == .recording || rec.state == .paused else { return }
                finishTaps += 1
                rec.finishAndUpload()
            } label: {
                ZStack {
                    Circle().fill(P.ink).frame(width: 42, height: 42)
                    if busy {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 16, weight: .heavy)).foregroundColor(.black)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel("Finish and save recording")
            .sinkyHaptic(finishTaps)
        }
    }

    private func roundIcon(_ name: String, tint: Color, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(P.surface2)
                .overlay(Circle().stroke(P.border, lineWidth: 1))
                .frame(width: size, height: size)
            Image(systemName: name)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundColor(tint)
        }
        .contentShape(Circle())
    }

    // MARK: Upload

    private var uploadFraction: Double { min(max(up.uploadFraction, 0), 1) }

    /// The ONE place an upload shows: what it is, where it's at, a real bar,
    /// and Manage (pause/cancel/retry) right there.
    private var uploadStrip: some View {
        let frac = uploadFraction
        let pct = Int((frac * 100).rounded())
        let items = up.pendingItems()
        let title = items.first?.title ?? "Recording"
        let stage: String = up.stage.isEmpty ? (frac < 1 ? "Uploading" : "Handing off") : up.stage
        let more = items.count > 1 ? " · 1 of \(items.count)" : ""
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.geist(size: 13, weight: .semibold)).foregroundColor(P.ink).lineLimit(1)
                    Text(stage + more).font(.geist(size: 11.5)).foregroundColor(P.textSec).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("\(pct)%")
                    .font(.geist(size: 15, weight: .medium, design: .monospaced)).monospacedDigit()
                    .foregroundColor(P.ink)
                Button { BottomChrome.shared.showPendingSheet = true } label: {
                    Text("Manage").font(.geist(size: 12.5, weight: .semibold)).foregroundColor(P.ink)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Capsule().fill(P.surface2))
                        .overlay(Capsule().stroke(P.border))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Manage upload")
            }
            GradientProgress(value: frac, height: 4, duration: 0.6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Uploading \(title), \(pct) percent")
    }

    // MARK: Upload / server progress (thin line + ring)

    /// 0…1 for whatever is in flight: the upload's bytes, else the server
    /// job's own progress. nil when nothing is in flight or it reports none.
    private var transferFraction: Double? {
        if up.isUploading { return uploadFraction }
        if let p = up.serverJob?.progress { return min(max(p / 100, 0), 1) }
        return nil
    }

    private var transferActive: Bool { up.isUploading || up.serverJob != nil }

    /// Server processing while the tabs are back: "62%" (or a spinner) above the disc.
    @ViewBuilder private func serverBadge(_ m: Mode) -> some View {
        if m == .tabs, let job = up.serverJob {
            SwiftUI.Group {
                if let p = job.progress {
                    Text("\(Int(p.rounded()))%")
                        .font(.geist(size: 10, weight: .medium, design: .monospaced)).monospacedDigit()
                        .foregroundColor(P.ink)
                } else {
                    ProgressView().controlSize(.mini).tint(P.accent)
                }
            }
            .padding(.horizontal, 7).frame(height: 18)
            .background(Capsule().fill(P.surface2))
            .overlay(Capsule().stroke(P.accent.opacity(0.6), lineWidth: 1))
            .offset(y: -(Self.disc / 2) - 2)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .accessibilityLabel(job.stage)
        }
    }

    // MARK: Centre disc: Record ⇄ ✓ Finish

    private func centreDisc(_ m: Mode) -> some View {
        let finishing = m == .recorder
        let ringFrac: Double? = transferActive ? transferFraction : nil
        let pulse = rec.state == .recording ? CGFloat(rec.level) * 0.07 : 0
        return Button {
            if finishing {
                guard rec.state == .recording || rec.state == .paused else { return }
                finishTaps += 1
                lastFinishAt = Date()
                rec.finishAndUpload()
            } else {
                // Back-to-back takes are allowed the moment the last one is
                // handed off — only a finger bounce (< 0.3 s) is ignored.
                guard Date().timeIntervalSince(lastFinishAt) > 0.3 else { return }
                recordTaps += 1
                onRecord()
            }
        } label: {
            ZStack {
                Circle().fill(P.bg).frame(width: Self.disc, height: Self.disc)
                Circle().stroke(finishing ? P.accent.opacity(0.75) : P.border, lineWidth: finishing ? 1.5 : 1)
                    .frame(width: Self.disc, height: Self.disc)
                    .scaleEffect(1 + pulse)
                    .animation(.linear(duration: 0.08), value: pulse)
                if let f = ringFrac, !finishing {
                    Circle().trim(from: 0, to: max(0.02, f))
                        .stroke(P.brand, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: Self.disc - 5, height: Self.disc - 5)
                        .animation(.easeInOut(duration: 0.8), value: f)
                }
                Circle().fill(P.ink).frame(width: 62, height: 62)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                discSymbol(finishing: finishing)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Server progress shows as the ring around the disc; the % and stage
        // live in the item's own row in Recent Activity — not twice down here.
        .accessibilityLabel(finishing ? "Finish and save recording" : "Record")
        .sinkyHaptic(recordTaps)
        .sinkyHaptic(finishTaps)
    }

    @ViewBuilder private func discSymbol(finishing: Bool) -> some View {
        if finishing && rec.state == .finishing {
            ProgressView().tint(Color.black)
                .transition(.opacity)
        } else if finishing {
            Image(systemName: "checkmark")
                .font(.system(size: 24, weight: .heavy))
                .foregroundColor(.black)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        } else {
            Circle().fill(P.accent).frame(width: 20, height: 20)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }

    // MARK: Tabs

    /// Live badges: Library = new since you last looked; More = processing now
    /// (red when something didn't work).
    @ViewBuilder private func tabBadge(for s: LibraryScreen.Section) -> some View {
        if notify.tabBadges {
            let n: Int = s == .library ? status.unseenLibrary : (s == .more ? status.activeJobs + status.unseenFailures : 0)
            if n > 0 {
                let red = s == .library || (s == .more && status.unseenFailures > 0)
                Text(n > 99 ? "99+" : "\(n)")
                    .font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundColor(red ? .white : .black)
                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(red ? Color(red: 1, green: 0.23, blue: 0.19) : P.accent))
                    .overlay(Capsule().stroke(Color.black, lineWidth: 1.5))
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel(s == .library ? "\(n) new" : "\(n) in progress")
            }
        }
    }

    private func tab(for s: LibraryScreen.Section) -> some View {
        let on = selection == s
        return Button {
            if on {
                // Already here: pop to this tab's root and scroll it to the top.
                BottomChrome.shared.reselect(s)
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = s }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: s.icon).font(.system(size: 19, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? AnyShapeStyle(P.brand) : AnyShapeStyle(P.textDim))
                    .overlay(alignment: .topTrailing) { tabBadge(for: s).offset(x: 12, y: -7) }
                Text(s.rawValue).font(.geist(size: 10.5, weight: .medium))
                    .foregroundColor(on ? P.ink : P.textDim)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background {
                if on {
                    Capsule().fill(Color.white.opacity(0.07))
                        .overlay(alignment: .bottom) { GradientRule(width: 18).padding(.bottom, 3) }
                        .matchedGeometryEffect(id: "sel", in: glassNS)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// "More" page: Collections · Query · Activity · Apple Watch · Settings, as cards.
struct MoreSection: View {
    let store: LibraryStore
    @ObservedObject private var up = Uploader.shared
    @ObservedObject private var status = StatusWatcher.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {   // no gap above the banner
            PageHeader(title: "More")
                .id(ScrollTop.anchor)
            VStack(spacing: 12) {
                tap(icon: "square.stack.fill", title: "Batches", sub: "Every channel, playlist and set of links you've fetched.", go: .collections)
                tap(icon: "sparkle.magnifyingglass", title: "Query", sub: "Ask anything across your whole library.", go: .query)
                tap(icon: "waveform.path.ecg", title: "Activity", sub: "What's processing, what's saved, and what needs a retry.", badge: max(up.pendingCount, status.activeJobs + status.unseenFailures), go: .jobs)
                tap(icon: "applewatch", title: "Apple Watch", sub: "Record from your wrist.", go: .watch)
                tap(icon: "gearshape.fill", title: "Settings", sub: "Account, text size, notifications and recording.", go: .settings)
            }
            .padding(16)
            }
        }
        .scrollsToTopOnReselect(.more)
    }

    private func tap(icon: String, title: String, sub: String, badge: Int = 0, go: LibraryScreen.Section) -> some View {
        Button { BottomChrome.shared.moreSub = go } label: { rowLabel(icon: icon, title: title, sub: sub, badge: badge) }
            .buttonStyle(.plain)
    }
    private func rowLabel(icon: String, title: String, sub: String, badge: Int) -> some View {
        SwiftUI.Group {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(P.surface2).frame(width: 38, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(P.edge))
                    Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(P.brand)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.geist(size: 16, weight: .semibold)).tracking(-0.3).foregroundColor(P.ink)
                        if badge > 0 {
                            Text("\(badge)").monoLabel(10, color: Color(hex: 0xF2A57F))
                                .padding(.horizontal, 8).frame(height: 20)
                                .background(P.accent.opacity(0.16)).clipShape(Capsule())
                        }
                    }
                    Text(sub).font(.geist(size: 12.5)).foregroundColor(P.textSec).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(P.textDim)
            }
            .padding(14)
            .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(P.edge))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}
