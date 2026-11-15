import TacitKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Devices", systemImage: "iphone") { DevicesSettingsView() }
            Tab("Hotkeys", systemImage: "keyboard") { HotkeysSettingsView() }
            Tab("Dictation", systemImage: "waveform") { DictationSettingsView() }
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
            DictationSection()
            GateSection()
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

private struct DictationSection: View {
    @Environment(DictationController.self) private var dictation

    var body: some View {
        Section {
            let stats = dictation.latency
            if stats.count == 0 {
                LabeledContent("Stop → inserted", value: "No dictations yet")
            } else {
                Check(label: "p50 stop → inserted < \(ms(DictationController.p50Budget))",
                      value: "\(ms(stats.p50)) · n = \(stats.count)",
                      passed: (stats.p50 ?? .infinity) < DictationController.p50Budget)
                Check(label: "p95 stop → inserted < \(ms(DictationController.p95Budget))",
                      value: ms(stats.p95), passed: (stats.p95 ?? .infinity) < DictationController.p95Budget)
            }
            if let last = dictation.lastBreakdown {
                LabeledContent("Last dictation") {
                    Text("tail + stop \(ms(last.tailAndStop)) · gate \(ms(last.gate)) · whisper \(ms(last.whisper)) · cleanup \(ms(last.cleanup)) · insert \(ms(last.insert)) (\(last.method.rawValue))")
                        .monospacedDigit()
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text("The M4 latency check expects small.en. Run it with the Fast model.")
        }
    }
}

private struct GateSection: View {
    @Environment(GateCalibration.self) private var calibration
    @Environment(GateEvaluation.self) private var evaluation
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        Section {
            LabeledContent("Threshold θ") {
                Text(calibration.measured == nil
                    ? String(format: "%.2f (default, no neutral takes yet)", calibration.threshold)
                    : String(format: "%.2f from %d neutral takes", calibration.threshold, calibration.neutralTakes))
                    .monospacedDigit()
            }
            HStack {
                Button("Compare WER With and Without the Gate", action: evaluation.start)
                    .disabled(evaluation.isRunning)
                Spacer()
                if let progress = evaluation.progress {
                    ProgressView(value: Double(progress.done), total: Double(progress.total)).frame(width: 120)
                }
            }
            if let problem = evaluation.problem { Text(problem).foregroundStyle(.red) }
            if let report = evaluation.report {
                Check(label: "Gate costs ≤ 1 WER point on \(GateEvaluation.takeCount) takes",
                      value: String(format: "%.1f%% with, %.1f%% without, %d takes", report.gatedWer * 100, report.ungatedWer * 100, report.takes),
                      passed: report.passed)
                if report.gatedEmpty > 0 {
                    Text("The gate let nothing through on \(report.gatedEmpty) takes.").foregroundStyle(.orange)
                }
                if report.takes < GateEvaluation.takeCount {
                    Text("Record \(GateEvaluation.takeCount - report.takes) more aloud or whisper takes for the full check.")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Mouth Gate")
        } footer: {
            Text("Uses the newest accepted aloud and whisper sentence takes from the Recorder.")
        }
        .task(id: recorder.savedCount) { await calibration.refresh(from: recorder.store) }
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
