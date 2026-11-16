import SwiftUI
import UniformTypeIdentifiers
import GeoSentinelKit
import GeoSentinelMacCore

struct ContentView: View {
    @State var result: Result<Analysis, Loader.Failure>?
    @State var speed: SpeedPreset = .car
    @State var picked: Int?
    @State var dropTargeted = false
    @State var lastURL: URL?
    @State var showImporter = false
    @State var replay: Double?          // nil = replay marker hidden
    @State var playing = false
    /// Drives the replay. 30 updates a second is smooth without being wasteful; it only runs while `playing`.
    private let ticker = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    /// For the headless self-test and previews: start in a given state.
    init(result: Result<Analysis, Loader.Failure>? = nil, speed: SpeedPreset = .car, picked: Int? = nil) {
        _result = State(initialValue: result); _speed = State(initialValue: speed); _picked = State(initialValue: picked)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Screen(result: result, picked: $picked, replay: $replay, isPlaying: playing, togglePlay: togglePlay,
                   openFile: { showImporter = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(ticker) { _ in advanceReplay() }
        .frame(minWidth: 760, minHeight: 520)
        .overlay { if dropTargeted { dropOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { open(url) } }
            }
            return true
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.allowedTypes) { r in
            if case .success(let url) = r {
                let scoped = url.startAccessingSecurityScopedResource()
                open(url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    static let allowedTypes: [UTType] = [.commaSeparatedText, UTType(filenameExtension: "gpx") ?? .xml, .xml]

    // MARK: pieces

    var toolbar: some View {
        HStack(spacing: 12) {
            Button { showImporter = true } label: { Label("Open file…", systemImage: "doc") }
                .keyboardShortcut("o")
            Spacer()
            Picker("Travel mode", selection: $speed) {
                ForEach(SpeedPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 260)
            .help("The fastest speed treated as believable. Pick the way this trip was really made: an aircraft trace analysed as a car trip will look faked.")
            .onChange(of: speed) { _ in if let u = lastURL { open(u) } }
        }
        .padding(10)
    }

    var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [8]))
            .foregroundStyle(Color.accentColor).background(Color.accentColor.opacity(0.08)).padding(8)
            .overlay(Text("Drop to check").font(.title2.bold()).foregroundStyle(Color.accentColor))
            .allowsHitTesting(false)
    }

    // MARK: actions

    func open(_ url: URL) {
        lastURL = url; picked = nil
        playing = false; replay = nil          // a new file starts with no replay: never carry one over
        result = Loader.analyse(url: url, speed: speed)
    }

    func togglePlay() {
        guard case .success(let a)? = result, !a.stats.isEmpty else { return }
        if playing { playing = false; return }
        // pressing play at (or past) the end starts again from the beginning
        if (replay ?? 0) >= 1 { replay = 0 } else if replay == nil { replay = 0 }
        playing = true
    }

    func advanceReplay() {
        guard playing, case .success(let a)? = result else { return }
        let next = replayStep(fraction: replay ?? 0, durationSeconds: a.duration, dt: 1.0 / 30.0)
        replay = next
        if next >= 1 { playing = false }       // stop at the end; the marker stays on the last position
    }
}

/// Scrolls only when asked to. A short list is laid out directly, which keeps it simple and lets the headless
/// render test actually show it; a long one needs a scroll view.
struct ConditionalScroll<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder var content: () -> Content
    var body: some View {
        if scrolls { ScrollView { content() } } else { content() }
    }
}

/// The window's content for one state, as a pure layout: no input handling and no AppKit-backed controls,
/// so it renders identically on screen and in the headless self-test.
struct Screen: View {
    /// A list longer than this scrolls. (A constant, so the headless render test can state what it expects.)
    static let scrollThreshold = 8
    let result: Result<Analysis, Loader.Failure>?
    @Binding var picked: Int?
    /// Replay position as a fraction 0...1, or nil when replay is off.
    var replay: Binding<Double?> = .constant(nil)
    var isPlaying: Bool = false
    var togglePlay: () -> Void = {}
    var openFile: () -> Void = {}

    var body: some View {
        switch result {
        case .none: welcome
        case .failure(let f): failure(f)
        case .success(let a): resultView(a)
        }
    }

    var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "location.viewfinder").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("Drop a GPS trace here").font(.title2.bold())
            Text("A .csv or .gpx file of recorded positions. GeoSentinel checks it for movement no real device could produce, and says why.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            Button("Open file…") { openFile() }.buttonStyle(.borderedProminent)
            Text("Your file is read on this Mac and never uploaded.").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(40)
    }

    func failure(_ f: Loader.Failure) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
            Text("This file could not be checked").font(.title3.bold())
            Text(f.description).textSelection(.enabled).multilineTextAlignment(.center).frame(maxWidth: 480)
            Button("Choose another file…") { openFile() }
        }
        .padding(40)
    }

    func resultView(_ a: Analysis) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                verdictBanner(a)
                if a.verdict == .clean {
                    Text("A clean result cannot rule out a careful fake: replaying realistic movement somewhere else leaves nothing impossible in the data.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                findingsList(a)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(width: 360, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(a.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if a.stats.reliable && a.stats.topSpeedMS > 0 { SpeedLegend(top: a.stats.topSpeedMS) }
                }
                TrackMap(analysis: a, highlight: picked, replay: replay.wrappedValue)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
                replayBar(a)
                Text("Plain latitude/longitude grid, no coastlines. \(a.stats.reliable ? "Path colour: speed (darker is faster). " : "")Green circle: start. Black square: end. Red diamond: a flagged position. Dashed red line: a jump between positions too far apart to be one path.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(minWidth: 380)
        }
    }

    func verdictBanner(_ a: Analysis) -> some View {
        let (icon, title, color): (String, String, Color) = {
            switch a.verdict {
            case .clean: return ("checkmark.circle.fill", "Looks genuine", .green)
            case .suspicious: return ("exclamationmark.triangle.fill", "Suspicious", .orange)
            case .likelySpoofed: return ("xmark.octagon.fill", "Likely faked", .red)
            }
        }()
        let stats = a.stats
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 34)).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.bold())
                    Text(summary(for: a)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !stats.isEmpty {
                // Duration is always known. Distance and speed are shown only when they can be stood behind: with
                // GPS error larger than the movement in a 10-second window the figures would look precise and be wrong.
                HStack(spacing: 8) {
                    StatTile(label: "Duration", value: Stats.durationText(stats.duration))
                    StatTile(label: "Positions", value: "\(stats.fixCount)")
                }
                if stats.reliable {
                    HStack(spacing: 8) {
                        StatTile(label: "Distance", value: Stats.distanceText(stats.distanceM))
                        StatTile(label: "Top speed", value: Stats.speedText(stats.topSpeedMS))
                    }
                    HStack(spacing: 8) {
                        StatTile(label: "Average", value: Stats.speedText(stats.averageSpeedMS))
                        StatTile(label: "Flagged", value: a.findings.isEmpty ? "none" : "\(grouped(a.findings).count) kind\(grouped(a.findings).count == 1 ? "" : "s")")
                    }
                } else {
                    Label("Too little movement, compared with this file's GPS error, to measure distance or speed.",
                          systemImage: "scope")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if stats.jumpCount > 0 {
                    Text("\(stats.jumpCount) impossible jump\(stats.jumpCount == 1 ? "" : "s") left out of these figures.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.45), lineWidth: 1.5))
        .accessibilityElement(children: .combine)
    }

    func replayBar(_ a: Analysis) -> some View {
        let on = replay.wrappedValue != nil
        return HStack(spacing: 10) {
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(isPlaying ? "Pause replay" : "Replay the recorded trip")
            // A plain bar that is also a slider: tapping and dragging scrub through the trip.
            ReplayScrubber(value: Binding(get: { replay.wrappedValue ?? 0 }, set: { replay.wrappedValue = $0 }))
                .frame(height: 22)
            Text(on ? Stats.durationText((replay.wrappedValue ?? 0) * a.duration) : "Replay")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 78, alignment: .trailing)
        }
    }

    @ViewBuilder func findingsList(_ a: Analysis) -> some View {
        if a.findings.isEmpty {
            Text("No findings.").foregroundStyle(.secondary)
        } else {
            Text("Why").font(.headline)
            let groups = grouped(a.findings)
            ConditionalScroll(scrolls: groups.count > Screen.scrollThreshold) {
                VStack(spacing: 6) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, f in
                        let first = f.fixIndices.first
                        let selected = picked != nil && f.fixIndices.contains(picked!)
                        Button { picked = (selected ? nil : first) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(f.check.capitalized).font(.subheadline.bold())
                                    Text(f.confidence.description).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Capsule().stroke(.secondary))
                                }
                                Text(f.reason).font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(first != nil ? "Highlights this position on the map" : "")
                    }
                }
            }
        }
    }

}
