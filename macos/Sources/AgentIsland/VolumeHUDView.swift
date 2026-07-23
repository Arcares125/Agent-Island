import SwiftUI

/// A finite, character-led volume HUD. Each input plays one short brace → pull
/// → ripple → settle sequence; there is no permanent animation or timer.
struct VolumeHUDView: View {
    let level: Float
    let direction: TugDirection
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pullAmount: CGFloat = 0
    @State private var loserReaction: CGFloat = 0
    @State private var ropeTension: CGFloat = 0

    // One knot per volume notch: macOS moves volume in sixteenths, so the rope
    // remains just as exact as the previous sixteen-box meter.
    private static let knotCount = 16
    private var lit: Int { litSegments(level: level, segmentCount: Self.knotCount) }
    private var percent: Int { Int((min(max(level, 0), 1) * 100).rounded()) }
    private var moment: VolumeTugMoment { volumeTugMoment(level: level, direction: direction) }
    private var animationEventID: String {
        "\(level.bitPattern)-\(directionID)-\(isActive)-\(reduceMotion)"
    }
    private var directionID: Int {
        switch direction {
        case .towardCodex: return 1
        case .towardClaude: return 2
        case .none: return 0
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("VOLUME \(percent)%")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(IslandPalette.text.opacity(0.92))
                .contentTransition(.numericText())

            HStack(spacing: 2) {
                mascot(.codex)
                LivingRopeTrack(
                    lit: lit,
                    level: level,
                    knotCount: Self.knotCount,
                    direction: direction,
                    tension: ropeTension
                )
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                mascot(.claude)
            }
            .frame(height: 32)

            Text(moment.label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.45)
                .foregroundStyle(winnerColor.opacity(0.86))
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: animationEventID) {
            await performTugAnimation()
        }
    }

    private var winnerColor: Color {
        switch direction {
        case .towardCodex: return Color(hex: 0xA995E8)
        case .towardClaude: return Color(hex: 0xF09A70)
        case .none: return IslandPalette.secondary
        }
    }

    private func mascot(_ provider: AgentProvider) -> some View {
        let isWinner = (provider == .codex && direction == .towardCodex)
            || (provider == .claude && direction == .towardClaude)
        let outward: CGFloat = provider == .codex ? -1 : 1
        let x = isWinner
            ? outward * 5 * pullAmount
            : -outward * 3.5 * loserReaction
        let y = isWinner ? -1.5 * pullAmount : 1.2 * loserReaction
        let rotation = isWinner
            ? Double(outward * 8 * pullAmount)
            : Double(-outward * 5 * loserReaction)

        return MascotView(
            provider: provider,
            phase: .thinking,
            size: 28,
            // The HUD owns this finite performance; suppress the mascot's normal
            // thinking loop so the pull reads as one deliberate action.
            isActive: false,
            showsExpression: false
        )
        .rotationEffect(.degrees(reduceMotion ? 0 : rotation), anchor: .bottom)
        .offset(x: reduceMotion ? 0 : x, y: reduceMotion ? 0 : y)
        .scaleEffect(
            reduceMotion ? 1 : (isWinner ? 1 + 0.07 * pullAmount : 1 - 0.03 * loserReaction),
            anchor: .bottom
        )
    }

    @MainActor
    private func performTugAnimation() async {
        pullAmount = 0
        loserReaction = 0
        ropeTension = 0
        guard isActive, direction != .none, !reduceMotion else { return }

        // Brace.
        withAnimation(.easeOut(duration: 0.08)) {
            pullAmount = 0.32
        }
        guard await pause(nanoseconds: 80_000_000) else { return }

        // Pull and make the opposing mascot lose its footing.
        withAnimation(.spring(response: 0.19, dampingFraction: 0.6)) {
            pullAmount = 1
            loserReaction = 1
            ropeTension = 1
        }
        guard await pause(nanoseconds: 190_000_000) else { return }

        // Release the visible tension while both characters recover. The rope
        // remains straight; its thickness and glow carry the force instead.
        withAnimation(.spring(response: 0.44, dampingFraction: 0.62)) {
            pullAmount = 0.24
            loserReaction = 0.18
            ropeTension = 0
        }
        guard await pause(nanoseconds: 300_000_000) else { return }

        withAnimation(.easeOut(duration: 0.18)) {
            pullAmount = 0
            loserReaction = 0
        }
    }

    @MainActor
    private func pause(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

/// A single Canvas draw keeps the rope, its sixteen knots, and the marker in one
/// render pass. `tension` briefly strengthens the perfectly straight rope, then
/// settles to zero; the line never bows or ripples vertically.
private struct LivingRopeTrack: View, Animatable {
    let lit: Int
    let level: Float
    let knotCount: Int
    let direction: TugDirection
    var tension: CGFloat

    var animatableData: CGFloat {
        get { tension }
        set { tension = newValue }
    }

    var body: some View {
        Canvas { context, size in
            guard knotCount > 0, size.width > 0, size.height > 0 else { return }
            let inset: CGFloat = 5
            let usableWidth = max(size.width - inset * 2, 1)
            let middleY = size.height / 2

            func point(at progress: CGFloat) -> CGPoint {
                straightVolumeRopePoint(
                    progress: progress,
                    inset: inset,
                    usableWidth: usableWidth,
                    middleY: middleY
                )
            }

            var rope = Path()
            rope.move(to: point(at: 0))
            rope.addLine(to: point(at: 1))

            let energy = direction == .towardClaude
                ? Color(hex: 0xE58A62)
                : Color(hex: 0x9480D8)
            context.stroke(
                rope,
                with: .color(energy.opacity(0.18 + 0.24 * tension)),
                lineWidth: 3.4 + 1.4 * tension
            )
            context.stroke(rope, with: .color(Color(hex: 0x77737E)), lineWidth: 1.1)

            for index in 0..<knotCount {
                let progress = (CGFloat(index) + 0.5) / CGFloat(knotCount)
                let center = point(at: progress)
                let knotRadius = 2 + 0.25 * tension
                let knot = CGRect(
                    x: center.x - knotRadius,
                    y: center.y - knotRadius,
                    width: knotRadius * 2,
                    height: knotRadius * 2
                )
                let providerColor = index < knotCount / 2
                    ? Color(hex: 0x9480D8)
                    : Color(hex: 0xE58A62)
                let color = index < lit
                    ? providerColor.opacity(0.96)
                    : IslandPalette.line.opacity(0.9)
                context.fill(
                    Path(roundedRect: knot, cornerRadius: 1),
                    with: .color(color)
                )
            }

            // The pale diamond is the exact absolute volume position; the rope
            // reaction communicates direction without changing that truth.
            let markerProgress = CGFloat(volumeMarkerProgress(level: level))
            let marker = point(at: markerProgress)
            let radius: CGFloat = 4 + 0.35 * tension
            var diamond = Path()
            diamond.move(to: CGPoint(x: marker.x, y: marker.y - radius))
            diamond.addLine(to: CGPoint(x: marker.x + radius, y: marker.y))
            diamond.addLine(to: CGPoint(x: marker.x, y: marker.y + radius))
            diamond.addLine(to: CGPoint(x: marker.x - radius, y: marker.y))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(Color.white.opacity(0.94)))
            context.stroke(diamond, with: .color(energy.opacity(0.9)), lineWidth: 1)
        }
    }
}
