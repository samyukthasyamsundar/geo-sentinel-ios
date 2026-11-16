import SwiftUI
import AppKit
import GeoSentinelKit
import GeoSentinelMacCore

@main struct GeoSentinelMacApp: App {
    init() {
        // Headless self-test: `GeoSentinelMac --render in.csv out.png [car|train|aircraft|foot] [pickedIndex]`
        // draws the real window content for a file to a PNG and exits, with no window and no permissions.
        let a = CommandLine.arguments
        if a.count >= 4 && a[1] == "--render" {
            let preset: SpeedPreset = a.count > 4 ? (["foot": .onFoot, "car": .car, "train": .train, "aircraft": .aircraft][a[4]] ?? .car) : .car
            let picked = a.count > 5 ? Int(a[5]) : nil                 // "-" or a non-number means none
            let replay = a.count > 6 ? Double(a[6]) : nil               // 0...1: draw the replay marker there
            let ok = MainActor.assumeIsolated { SelfTest.render(input: a[2], output: a[3], speed: preset, picked: picked, replay: replay) }
            exit(ok ? 0 : 1)
        }
    }
    var body: some Scene {
        WindowGroup("GeoSentinel") { ContentView() }
            .windowResizability(.contentMinSize)
            .defaultSize(width: 980, height: 640)
    }
}

enum SelfTest {
    @MainActor static func render(input: String, output: String, speed: SpeedPreset, picked: Int?, replay: Double? = nil) -> Bool {
        let result: Result<Analysis, Loader.Failure>? = input == "-" ? nil : Loader.analyse(url: URL(fileURLWithPath: input), speed: speed)
        // Render the real layout (Screen) with a header strip that mimics the toolbar's content as plain text.
        struct Harness: View {
            let result: Result<Analysis, Loader.Failure>?; let speed: SpeedPreset
            @State var picked: Int?
            @State var replay: Double?
            var body: some View {
                VStack(spacing: 0) {
                    HStack { Text("Open file…").font(.body); Spacer(); Text("Travel mode: \(speed.rawValue) (\(Int(speed.kmh)) km/h)").font(.body) }
                        .padding(10)
                    Divider()
                    Screen(result: result, picked: $picked, replay: $replay).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: 980, height: 640).background(Color.white)
            }
        }
        let view = Harness(result: result, speed: speed, picked: picked, replay: replay)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); return false }
        do { try png.write(to: URL(fileURLWithPath: output)); print("rendered \(output)"); return true }
        catch { print("write failed: \(error)"); return false }
    }
}
