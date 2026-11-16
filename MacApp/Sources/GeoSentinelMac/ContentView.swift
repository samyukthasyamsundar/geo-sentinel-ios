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

    /// For the headless self-test and previews: start in a given state.
    init(result: Result<Analysis, Loader.Failure>? = nil, speed: SpeedPreset = .car, picked: Int? = nil) {
        _result = State(initialValue: result); _speed = State(initialValue: speed); _picked = State(initialValue: picked)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Screen(result: result, picked: $picked, openFile: { showImporter = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        result = Loader.analyse(url: url, speed: speed)
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
                Text(summary(for: a)).font(.callout)
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
            VStack(alignment: .leading, spacing: 6) {
                Text(a.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
                TrackMap(analysis: a, highlight: picked)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                Text("Plain latitude/longitude grid, no coastlines. Green circle: start. Black square: end. Red diamond: a flagged position. Dashed line: a jump between positions too far apart to be one path.")
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
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.title).foregroundStyle(color)
            Text(title).font(.title2.bold())
        }
        .accessibilityElement(children: .combine)
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
