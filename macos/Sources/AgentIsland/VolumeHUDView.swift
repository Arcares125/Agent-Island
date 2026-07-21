import SwiftUI

/// Transient HUD shown when the system volume changes: Codex (left) and Claude
/// (right) tug a horizontal segmented level bar. The bar fill reflects the
/// absolute level; the mascot that "won" the last tug leans toward its side.
struct VolumeHUDView: View {
    let level: Float
    let direction: TugDirection
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let segmentCount = 10
    private var lit: Int { litSegments(level: level, segmentCount: Self.segmentCount) }
    private var percent: Int { Int((min(max(level, 0), 1) * 100).rounded()) }

    var body: some View {
        VStack(spacing: 6) {
            Text("VOLUME \(percent)%")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(IslandPalette.secondary)
                .contentTransition(.numericText())

            HStack(spacing: 9) {
                mascot(.codex, tugging: direction == .towardCodex)
                segmentedBar
                mascot(.claude, tugging: direction == .towardClaude)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var segmentedBar: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let count = CGFloat(Self.segmentCount)
            let segmentWidth = max((geo.size.width - spacing * (count - 1)) / count, 1)
            HStack(spacing: spacing) {
                ForEach(0..<Self.segmentCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(index < lit ? litColor(index) : IslandPalette.line)
                        .frame(width: segmentWidth)
                }
            }
        }
        .frame(height: 12)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: lit)
    }

    private func litColor(_ index: Int) -> Color {
        // Blend Codex purple (left half) into Claude orange (right half).
        let midpoint = Self.segmentCount / 2
        return Color(hex: index < midpoint ? 0x9480D8 : 0xE58A62).opacity(0.9)
    }

    private func mascot(_ provider: AgentProvider, tugging: Bool) -> some View {
        MascotView(
            provider: provider,
            phase: .thinking,
            size: 26,
            isActive: isActive,
            showsExpression: false
        )
        .offset(y: tugging && !reduceMotion ? -3 : 0)
        .scaleEffect(tugging && !reduceMotion ? 1.12 : 1.0, anchor: .bottom)
        .animation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.58),
            value: tugging
        )
    }
}
