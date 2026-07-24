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
    /// How far around the hue wheel the sweep travels from one end of the set to
    /// the other. Narrow on purpose: neighbouring hues read as one gradient, while
    /// a wide span turns the bars back into a rainbow of separate colours.
    private static let hueSpan = 0.11
    /// The sweep also ramps in weight, which is what makes it read as a gradient
    /// rather than a flat tint: the leading end sits back, the trailing end pops.
    private static let dimStop = (saturation: 0.52, brightness: 0.68, opacity: 0.55)
    private static let vividStop = (saturation: 0.88, brightness: 1.0, opacity: 0.95)

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
                // All five bars are one path filled with one gradient, so the sweep
                // runs *across the set* instead of each bar taking its own colour.
                // It also drops the fill count from five to one.
                var bars = Path()
                for i in 0..<Self.barCount {
                    let height = barHeight(i)
                    let rect = CGRect(
                        x: CGFloat(i) * (barWidth + spacing),
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    )
                    bars.addRoundedRect(
                        in: rect,
                        cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2)
                    )
                }
                context.fill(
                    bars,
                    with: .linearGradient(
                        sweep(hue0: hue0),
                        startPoint: CGPoint(x: 0, y: size.height / 2),
                        endPoint: CGPoint(x: size.width, y: size.height / 2)
                    )
                )
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

    /// The horizontal sweep: two neighbouring hues, the second brighter and more
    /// opaque than the first. `hue0` drifts the whole band around the wheel over
    /// time, so the gradient keeps the "rotating changing colour" behaviour.
    private func sweep(hue0: Double) -> Gradient {
        Gradient(colors: [
            Color(
                hue: hue0,
                saturation: Self.dimStop.saturation,
                brightness: Self.dimStop.brightness
            ).opacity(Self.dimStop.opacity),
            Color(
                hue: (hue0 + Self.hueSpan).truncatingRemainder(dividingBy: 1.0),
                saturation: Self.vividStop.saturation,
                brightness: Self.vividStop.brightness
            ).opacity(Self.vividStop.opacity),
        ])
    }
}
