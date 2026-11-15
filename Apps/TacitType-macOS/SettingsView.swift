import TacitKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Devices", systemImage: "iphone") { DevicesSettingsView() }
            Tab("Hotkeys", systemImage: "keyboard") { PlaceholderView(title: "Hotkeys", milestone: "M4") }
            Tab("Dictation", systemImage: "waveform") { PlaceholderView(title: "Dictation", milestone: "M4") }
            Tab("Silent Dictation", systemImage: "mouth") { PlaceholderView(title: "Silent Dictation", milestone: "M5") }
            Tab("Data", systemImage: "externaldrive") { DataSettingsView() }
            Tab("Diagnostics", systemImage: "stethoscope") { DiagnosticsView() }
        }
        .frame(width: 560, height: 520)
    }
}

private struct DiagnosticsView: View {
    @Environment(DeviceManager.self) private var devices

    var body: some View {
        Form {
            CaptureSection()
            Section("Link") {
                if let clock = devices.clockEstimate {
                    LabeledContent("Round trip", value: String(format: "%.1f ms", clock.roundTrip * 1000))
                    LabeledContent("iPhone clock offset", value: String(format: "%+.3f s", clock.offset))
                } else {
                    LabeledContent("Clock sync", value: "Not connected")
                }
                LabeledContent("This Mac's id", value: devices.macId.uuidString)
                    .textSelection(.enabled)
            }
            Section("Versions") {
                LabeledContent("Protocol version", value: "\(Constants.protocolVersion)")
                LabeledContent("Feature schema", value: "\(Constants.featureSchemaVersion)")
                LabeledContent("Bonjour service", value: Constants.bonjourServiceType)
            }
        }
        .formStyle(.grouped)
    }
}

struct PlaceholderView: View {
    let title: String
    let milestone: String

    var body: some View {
        ContentUnavailableView(title, systemImage: "hammer", description: Text("Arrives in \(milestone)."))
            .frame(minWidth: 360, minHeight: 240)
    }
}

private struct CaptureSection: View {
    @Environment(DeviceManager.self) private var devices
    @Environment(SessionManager.self) private var sessions
    @Environment(CaptureBench.self) private var bench

    var body: some View {
        Section {
            if let status = devices.lastStatus {
                LabeledContent("iPhone", value: "\(status.state.rawValue) · face \(status.faceDetected ? "detected" : "not detected") · thermal \(status.thermalState.rawValue)")
                if status.thermalState == .serious || status.thermalState == .critical {
                    Text("The iPhone is hot. Frame rate may drop.").foregroundStyle(.orange)
                }
            }
            LabeledContent("Start → first face frame") {
                Text(latencyText(sessions.firstFrameLatency)).monospacedDigit()
            }

            HStack {
                Button("Measure Start Latency (\(CaptureBench.latencyTries) tries)", action: bench.measureLatency)
                Button("Record \(CaptureBench.sessionSeconds) s Session", action: bench.recordSession)
                Spacer()
                if bench.isRunning { Button("Stop", action: bench.cancel) }
            }
            .disabled(!devices.isConnected || (bench.isRunning ? false : sessions.isActive))

            switch bench.phase {
            case .idle: EmptyView()
            case let .measuringLatency(done, total): ProgressView(value: Double(done), total: Double(total)) { Text("Try \(done + 1) of \(total)") }
            case let .recording(startedAt, endsAt):
                ProgressView(timerInterval: startedAt ... endsAt, countsDown: true) { Text("Recording. Keep your face in view.") }
            }
            if let problem = bench.problem { Text(problem).foregroundStyle(.red) }

            if let run = bench.latency {
                Check(label: "p95 start → first frame < \(Int(CaptureBench.latencyBudget * 1000)) ms",
                      value: "p50 \(ms(run.stats.p50)) · p95 \(ms(run.stats.p95)) · n = \(run.stats.count)",
                      passed: run.stats.count == CaptureBench.latencyTries && (run.stats.p95 ?? .infinity) < CaptureBench.latencyBudget)
                LabeledContent("From start arriving on the iPhone (est.)") {
                    Text("p50 \(ms(run.onIPhone.p50)) · p95 \(ms(run.onIPhone.p95))").monospacedDigit()
                }
                ForEach(run.failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            if let result = bench.session {
                let m = result.metrics
                Check(label: "fps ≥ \(Int(CaptureBench.minFps))", value: String(format: "%.2f fps, %d frames, %.1f s", m.measuredFps, m.frameCount, m.faceDuration),
                      passed: m.measuredFps >= CaptureBench.minFps)
                Check(label: "Dropped frames < 1%", value: String(format: "%d (%.2f%%)", m.droppedFrames, m.droppedRatio * 100),
                      passed: m.droppedRatio < CaptureBench.maxDroppedRatio)
                Check(label: "No audio gaps", value: String(format: "%d gaps, %.1f s audio", m.audioGapsFilled, m.audioDuration),
                      passed: m.audioGapsFilled == 0 && m.audioSampleCount > 0)
                LabeledContent("Tracked", value: String(format: "%.1f%%", m.trackedRatio * 100))
                LabeledContent("Ended", value: String(describing: result.endReason))
            }
        } header: {
            Text("Capture")
        } footer: {
            Text("Also check on the iPhone that the green camera dot is off whenever it isn't capturing.")
        }
    }

    private func latencyText(_ stats: LatencyStats) -> String {
        stats.count == 0 ? "No sessions yet" : "p50 \(ms(stats.p50)) · p95 \(ms(stats.p95)) · last \(stats.count)"
    }
}

private struct Check: View {
    let label: String
    let value: String
    let passed: Bool

    var body: some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            Label(label, systemImage: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(passed ? .green : .red)
        }
    }
}

private func ms(_ seconds: Double?) -> String {
    seconds.map { String(format: "%.0f ms", $0 * 1000) } ?? "–"
}
