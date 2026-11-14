import SwiftUI
import TacitKit

struct RecorderView: View {
    @Environment(RecorderModel.self) private var recorder
    @Environment(DeviceManager.self) private var devices

    var body: some View {
        HStack(spacing: 0) {
            RecorderSidebar()
                .frame(width: 230)
            Divider()
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(KeyCatcher { recorder.handle($0) })
        .task { recorder.prepareIfNeeded() }
    }

    private var stage: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 12)
            if recorder.phase == .sittingDone {
                SittingDoneView()
            } else if let prompt = recorder.currentPrompt {
                PromptView(prompt: prompt)
                Spacer(minLength: 12)
                PhaseView()
                    .frame(height: 230)
            }
            Spacer(minLength: 12)
            KeyHints()
        }
        .padding(24)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let block = recorder.currentBlock {
                Text(block.title).font(.headline)
                if recorder.currentPrompt != nil {
                    Text("Take \(recorder.positions[recorder.blockIndex] + 1) of \(block.prompts.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            if let thermal = devices.lastStatus?.thermalState, thermal == .serious || thermal == .critical {
                Label("iPhone is hot. Frame rate may drop.", systemImage: "thermometer.high")
                    .foregroundStyle(.orange)
            }
            Circle()
                .fill(devices.isConnected ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(devices.statusLine).foregroundStyle(.secondary)
        }
    }
}

// MARK: Sidebar

private struct RecorderSidebar: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Blocks")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            ForEach(Array(recorder.blocks.enumerated()), id: \.element.id) { index, block in
                BlockRow(block: block, done: recorder.positions[index], isCurrent: index == recorder.blockIndex) {
                    recorder.select(block: index)
                }
            }
            .disabled(!recorder.canSwitchBlock)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Saved this sitting", value: "\(recorder.savedCount)")
                LabeledContent("Face and audio offset") {
                    Text(recorder.sittingOffsetMs.map { String(format: "%+.1f ms", $0) } ?? "Not measured")
                }
                Button("New Sitting") { recorder.newSitting() }
                    .disabled(!recorder.canSwitchBlock)
                Button("Show Sessions in Finder") {
                    try? FileManager.default.createDirectory(at: recorder.store.root, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(recorder.store.root)
                }
            }
            .font(.callout)
            .monospacedDigit()
            .padding(8)
        }
        .padding(12)
        .focusable(false)
    }
}

private struct BlockRow: View {
    let block: RecorderBlock
    let done: Int
    let isCurrent: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack {
                Image(systemName: done >= block.prompts.count ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done >= block.prompts.count ? Color.green : Color.secondary)
                Text(block.title)
                Spacer()
                Text("\(min(done, block.prompts.count))/\(block.prompts.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isCurrent ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Stage

private struct PromptView: View {
    let prompt: RecorderPrompt

    var body: some View {
        VStack(spacing: 16) {
            Text(instruction)
                .font(.title3.weight(.semibold))
                .foregroundStyle(prompt.style == .silent ? Color.purple : Color.secondary)
            Text(prompt.text)
                .font(.system(size: 44, weight: .semibold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .lineLimit(3)
        }
        .frame(maxWidth: 640)
    }

    private var instruction: String {
        switch prompt.style {
        case .aloud: "Say it aloud"
        case .whisper: "Whisper it"
        case .silent: "Mouth it silently. Make no sound."
        case .negative: "Do this for \(Int(prompt.timeLimit)) seconds"
        }
    }
}

private struct PhaseView: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        VStack(spacing: 12) {
            switch recorder.phase {
            case .ready:
                Text("Press Space to start")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                if recorder.currentBlock?.kind == .syncCheck { SyncHistory() }
            case let .countdown(count):
                Text("\(count)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            case let .capturing(startedAt, endsAt):
                Label("Recording", systemImage: "record.circle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)
                ProgressView(timerInterval: startedAt ... endsAt, countsDown: true) { EmptyView() }
                    .frame(maxWidth: 360)
                Text("Press Space to stop").foregroundStyle(.secondary)
            case .finishing:
                ProgressView()
            case .review:
                if let take = recorder.take { ReviewView(take: take) }
            case .sittingDone:
                EmptyView()
            }
            if let message = recorder.message {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReviewView: View {
    @Environment(RecorderModel.self) private var recorder
    let take: RecorderModel.Take

    var body: some View {
        VStack(spacing: 10) {
            ReviewStrip(trace: take.trace)
                .frame(height: 120)
            HStack(spacing: 14) {
                Label("Jaw open", systemImage: "circle.fill").foregroundStyle(.blue)
                Label("Mouth close", systemImage: "circle.fill").foregroundStyle(.orange)
                Label("Audio", systemImage: "waveform").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f s · %.1f fps · tracked %.0f%%", take.duration,
                            take.session.manifest.measuredFps, take.session.manifest.trackedRatio * 100))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)

            if let sync = take.sync {
                Label(String(format: "Audio is %+.1f ms from the face. The limit is ±20 ms.", sync.lagMs),
                      systemImage: sync.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(sync.passed ? .green : .red)
            }
            if take.flags.isEmpty {
                Label("Looks good", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                ForEach(take.flags, id: \.self) { flag in
                    Label(flag.advice, systemImage: "flag.fill").foregroundStyle(.orange)
                }
            }
            if recorder.currentBlock?.kind == .syncCheck { SyncHistory() }
        }
        .frame(maxWidth: 640)
    }
}

/// Waveform with the jaw and lip curves on the same time axis, and a playhead during playback.
private struct ReviewStrip: View {
    @Environment(RecorderModel.self) private var recorder
    let trace: ReviewTrace

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let barWidth = size.width / Double(trace.waveform.count)
            var bars = Path()
            for (index, level) in trace.waveform.enumerated() {
                let height = max(1, level * (size.height - 4))
                bars.addRect(CGRect(x: Double(index) * barWidth, y: mid - height / 2, width: max(barWidth - 0.5, 0.5), height: height))
            }
            context.fill(bars, with: .color(.secondary.opacity(0.45)))
            context.stroke(curve(trace.jawOpen, in: size), with: .color(.blue), lineWidth: 2)
            context.stroke(curve(trace.mouthClose, in: size), with: .color(.orange), lineWidth: 2)
        }
        .overlay {
            TimelineView(.animation) { _ in
                GeometryReader { proxy in
                    if let time = recorder.playheadTime {
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 1.5)
                            .offset(x: time / trace.duration * proxy.size.width)
                    }
                }
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Blendshape values run 0 … 1 from the bottom of the strip to the top.
    private func curve(_ points: [ReviewTrace.Point], in size: CGSize) -> Path {
        var path = Path()
        for (index, point) in points.enumerated() {
            let position = CGPoint(x: point.time / trace.duration * size.width,
                                   y: (1 - min(max(point.value, 0), 1)) * (size.height - 6) + 3)
            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        return path
    }
}

private struct SyncHistory: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        if !recorder.syncRuns.isEmpty {
            HStack(spacing: 8) {
                Text("Last runs")
                ForEach(recorder.syncRuns.suffix(5)) { run in
                    Text(run.lagMs.map { String(format: "%+.1f", $0) } ?? "none")
                        .foregroundStyle(run.passed ? .green : .red)
                }
                if recorder.syncPassedFiveInARow {
                    Label("5 in a row under 20 ms", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

private struct SittingDoneView: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        ContentUnavailableView {
            Label(allDone ? "Sitting complete" : "Block complete", systemImage: "checkmark.circle")
        } description: {
            Text("\(recorder.savedCount) takes saved in this sitting.")
        } actions: {
            Button("New Sitting") { recorder.newSitting() }
        }
    }

    private var allDone: Bool {
        zip(recorder.blocks, recorder.positions).allSatisfy { $1 >= $0.prompts.count }
    }
}

private struct KeyHints: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        HStack(spacing: 18) {
            ForEach(hints, id: \.key) { hint in
                HStack(spacing: 6) {
                    Text(hint.key)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    Text(hint.label).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .frame(height: 24)
    }

    private var hints: [(key: String, label: String)] {
        switch recorder.phase {
        case .ready: [("Space", "Start"), ("S", "Skip")]
        case .countdown: [("Space", "Cancel")]
        case .capturing: [("Space", "Stop")]
        case .review: [("→", "Accept and next"), ("R", "Redo"), ("⌫", "Discard"), ("Space", "Play")]
        case .finishing, .sittingDone: []
        }
    }
}

private extension TakeQuality.Flag {
    var advice: String {
        switch self {
        case .poorTracking: "Face tracking was poor. Keep your whole face in view of the iPhone."
        case .noSpeech: "We didn't hear any speech."
        case .audibleInSilent: "We heard you. Redo silently?"
        case .tooShort: "The take was too short."
        case .tooLong: "The take ran long for this prompt."
        case .syncOffset: "Face and audio are more than 20 ms apart."
        case .syncFailed: "Couldn't match the sound to your jaw. Say each \"pa\" clearly."
        case .incomplete: "The capture ended early. The end of the take may be missing."
        }
    }
}

// MARK: Keyboard

/// Sends the Recorder's keys to `handler` while its window is key, whatever has focus.
private struct KeyCatcher: NSViewRepresentable {
    let handler: (RecorderModel.Key) -> Bool

    final class Coordinator {
        var monitor: Any?
        var handler: ((RecorderModel.Key) -> Bool)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.handler = handler
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak coordinator] event in
            let blocked: NSEvent.ModifierFlags = [.command, .control, .option]
            guard event.modifierFlags.isDisjoint(with: blocked), let key = Self.key(for: event.keyCode) else { return event }
            let windowNumber = event.windowNumber
            let isRepeat = event.isARepeat
            let handled = MainActor.assumeIsolated {
                guard let view, view.window?.windowNumber == windowNumber else { return false }
                // A held key must not start, stop and restart takes.
                return isRepeat || coordinator?.handler?(key) == true
            }
            return handled ? nil : event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    private static func key(for keyCode: UInt16) -> RecorderModel.Key? {
        switch keyCode {
        case 49: .space
        case 15: .redo // R
        case 124: .accept // →
        case 51, 117: .discard // Delete, Forward Delete
        case 1: .skip // S
        default: nil
        }
    }
}
