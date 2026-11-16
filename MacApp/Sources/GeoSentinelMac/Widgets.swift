import SwiftUI
import GeoSentinelKit
import GeoSentinelMacCore

/// One headline figure. Plain views only (no AppKit-backed controls) so it renders the same on screen and in the
/// headless self-test.
struct StatTile: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
        .accessibilityElement(children: .combine)
    }
}

/// The colour key for the path: the same ramp the map uses, with its two end labels in words.
struct SpeedLegend: View {
    let top: Double
    var body: some View {
        HStack(spacing: 6) {
            Text("slow").font(.caption2).foregroundStyle(.secondary)
            LinearGradient(
                colors: SpeedRamp.steps.map { Color(red: $0.r, green: $0.g, blue: $0.b) },
                startPoint: .leading, endPoint: .trailing)
                .frame(width: 90, height: 8).clipShape(Capsule())
                .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
            Text(top > 0 ? Stats.speedText(top) : "fast").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Path colour shows speed, from slow (light) to \(top > 0 ? Stats.speedText(top) : "fast") (dark)")
    }
}

/// A drag-to-scrub bar for the replay, built from plain shapes so it renders in the headless test.
struct ReplayScrubber: View {
    @Binding var value: Double      // 0...1
    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width)
            let x = CGFloat(min(max(value, 0), 1)) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 6)
                Capsule().fill(Color.accentColor).frame(width: x, height: 6)
                Circle().fill(Color.white).overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: 16, height: 16).offset(x: x - 8)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                value = Double(min(max(v.location.x / w, 0), 1))
            })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Replay position")
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
    }
}
