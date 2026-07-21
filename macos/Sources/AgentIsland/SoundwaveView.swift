import SwiftUI

/// The equalizer's bar values live in their own observable object rather than on
/// `IslandModel`, so the ~30 fps updates invalidate only the equalizer instead of
/// every view bound to the model (mascots, session rows, tab bar, shelf).
@MainActor
final class SpectrumStore: ObservableObject {
    @Published private(set) var bars: [Float] = []

    func update(_ bars: [Float]) {
        guard bars != self.bars else { return }
        self.bars = bars
    }
}

/// Now-playing equalizer: soft translucent capsule bars whose heights come from the FFT
/// spectrum and whose hue sweeps continuously (the "rotating changing color").
struct SoundwaveView: View {
    @ObservedObject var store: SpectrumStore
    let isActive: Bool
    /// Sized for the expanded strip by default; the notch wing passes a smaller
    /// set so the bars fit beside the menu-bar-height status row.
    var barWidth: CGFloat = 6
    var spacing: CGFloat = 5
    var maxBarHeight: CGFloat = 26

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barCount = 5
    /// Slightly see-through so the bars read as a soft accent rather than a bold
    /// block against the notch.
    private static let barOpacity: Double = 0.62

    private var contentWidth: CGFloat {
        CGFloat(Self.barCount) * barWidth + CGFloat(Self.barCount - 1) * spacing
    }

    /// One `Canvas` draw pass rather than five `Capsule` views: at 20 fps the
    /// per-view layout/diff/layer-commit work dominated the whole feature's cost.
    var body: some View {
        let animates = isActive && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animates)) { timeline in
            let hue0 = animates ? huePhase(at: timeline.date.timeIntervalSinceReferenceDate, speed: 0.06) : 0
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                for i in 0..<Self.barCount {
                    let height = barHeight(i)
                    let rect = CGRect(
                        x: CGFloat(i) * (barWidth + spacing),
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(color(for: i, hue0: hue0).opacity(Self.barOpacity))
                    )
                }
            }
            .frame(width: contentWidth, height: maxBarHeight)
        }
    }

    /// Silence rests at a dot (height == width); a full band fills the row.
    private func barHeight(_ i: Int) -> CGFloat {
        let bars = store.bars
        let v = i < bars.count ? CGFloat(min(max(bars[i], 0), 1)) : 0
        return barWidth + v * (maxBarHeight - barWidth)
    }

    /// Chromatic spread: the 5 bars fan across the full hue wheel (a rainbow),
    /// and the whole rainbow slowly rotates via `hue0` ("rotating changing color").
    private func color(for i: Int, hue0: Double) -> Color {
        let hue = (hue0 + Double(i) / Double(Self.barCount)).truncatingRemainder(dividingBy: 1.0)
        return Color(hue: hue, saturation: 0.68, brightness: 1.0)
    }
}
