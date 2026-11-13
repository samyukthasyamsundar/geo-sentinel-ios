import SwiftUI
import GeoSentinelKit

struct ContentView: View {
    @StateObject private var source = LocationSource()
    @State private var result: (verdict: Verdict, findings: [Finding])?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Records your phone's real GPS and checks it for signs of faking. Everything stays on this phone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Recording") {
                    Button(source.isRecording ? "Stop" : "Start recording") {
                        if source.isRecording { source.stop(); result = source.recorder.assess() } else { result = nil; source.start() }
                    }
                    LabeledContent("Fixes recorded", value: "\(source.fixCount)")
                    if source.rejectedCount > 0 { LabeledContent("Invalid fixes ignored", value: "\(source.rejectedCount)") }
                    if let e = source.lastError { Text(e).foregroundStyle(.red) }
                }
                if source.isSimulatedBySoftware {
                    Section {
                        Label("iOS reports that some of these locations were produced by software, not by the GPS hardware.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if let r = result { verdictSection(r) }
                else if !source.isRecording && source.fixCount > 0 {
                    Section { Text("Tap Stop to see the result.").foregroundStyle(.secondary) }
                } else if source.isRecording && source.fixCount < 20 {
                    Section { Text("Keep moving for a minute or two so there is enough data to judge.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("GeoSentinel")
        }
    }

    @ViewBuilder private func verdictSection(_ r: (verdict: Verdict, findings: [Finding])) -> some View {
        Section("Result") {
            switch r.verdict {
            case .clean:
                Label("Looks genuine", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .suspicious:
                Label("Suspicious", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .likelySpoofed:
                Label("Likely faked", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            if r.verdict == .clean {
                Text("Nothing impossible was found. This cannot catch a careful fake: replayed realistic movement leaves no trace-only signs.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        if !r.findings.isEmpty {
            Section("Why") {
                ForEach(Array(r.findings.enumerated()), id: \.offset) { _, f in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(f.check.capitalized) (\(f.confidence.description))").font(.subheadline.bold())
                        Text(f.reason).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
