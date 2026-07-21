import SwiftUI

/// The option number, with a band of interference sweeping down through it.
///
/// The digit stays legible for the whole pass — these numbers double as the
/// keyboard shortcut for the row, so hiding them would cost more than the motion
/// is worth.
///
/// Drawn in a single `Canvas` rather than one `Text` per slice: the equalizer
/// taught us that per-view layout and layer commits dominate at these frame
/// rates, and eight stacked `Text` views per badge would be the same mistake.
struct BandScrambleDigit: View {
    let digit: Int
    /// Painted behind the band before the junk glyph, so the real digit does not
    /// show through. Must match the badge the digit sits on.
    let background: Color
    let foreground: Color
    var fontSize: CGFloat = 9.5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?

    private static let sliceCount = 8
    private static let bandSlices = 2
    private static let duration: TimeInterval = 0.85
    /// The band moves one slice at a time, so there is nothing to gain from
    /// drawing faster than the slices change.
    private static let frameRate: Double = 14

    var body: some View {
        Group {
            if let startedAt {
                TimelineView(.animation(minimumInterval: 1 / Self.frameRate, paused: false)) { timeline in
                    canvas(elapsed: timeline.date.timeIntervalSince(startedAt), now: timeline.date)
                }
            } else {
                plain
            }
        }
        .onAppear(perform: begin)
    }

    private var plain: some View {
        Text("\(digit)")
            .font(.system(size: fontSize, weight: .heavy, design: .monospaced))
            .foregroundStyle(foreground)
    }

    /// Fires once when the question arrives. Looping would turn a question into a
    /// spinner, and the card can sit unanswered for minutes.
    private func begin() {
        guard !reduceMotion, startedAt == nil else { return }
        startedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) {
            startedAt = nil
        }
    }

    private func canvas(elapsed: TimeInterval, now: Date) -> some View {
        let progress = elapsed / Self.duration
        let band = scrambleBandRange(
            progress: progress, sliceCount: Self.sliceCount, bandSlices: Self.bandSlices)
        // One seed per frame: the junk changes between frames but holds still
        // within one, so a redraw never double-scrambles.
        let seed = Int(now.timeIntervalSinceReferenceDate * Self.frameRate)

        return Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let font = Font.system(size: fontSize, weight: .heavy, design: .monospaced)
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)

            // The digit is drawn once, then only the banded slices are painted
            // over — three draw calls instead of one per slice.
            context.draw(
                context.resolve(Text("\(digit)").font(font).foregroundStyle(foreground)),
                at: centre, anchor: .center)

            guard !band.isEmpty else { return }
            let sliceHeight = size.height / CGFloat(Self.sliceCount)

            for slice in band {
                let rect = CGRect(
                    x: 0, y: CGFloat(slice) * sliceHeight,
                    width: size.width, height: sliceHeight)
                let junk = String(scrambleCharacter(seed: seed &+ slice))

                context.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    layer.fill(Path(rect), with: .color(background))
                    layer.draw(
                        layer.resolve(Text(junk).font(font).foregroundStyle(foreground)),
                        at: centre, anchor: .center)
                }
            }
        }
    }
}

/// A question the agent is actively blocked on, answerable in place.
///
/// The read-only `PendingQuestionCard` still exists for questions scraped from a
/// transcript. This one only appears when the answer transport is holding an
/// agent open, which is why it can offer buttons at all.
struct AnswerableQuestionCard: View {
    @ObservedObject var model: IslandModel
    let ask: AskRequestMessage
    let accent: Color

    @State private var pickedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            prompt
            options
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(accent.opacity(0.42), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent is waiting for your answer")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)
            Text(ask.question.header ?? "Agent's question")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(accent)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let workspace = ask.workspaceName {
                Text(workspace.uppercased())
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(IslandPalette.secondary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var prompt: some View {
        Text(ask.question.prompt)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(IslandPalette.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var options: some View {
        VStack(spacing: 4) {
            ForEach(Array(ask.question.options.enumerated()), id: \.element.id) { index, option in
                AnswerOptionRow(
                    index: index,
                    option: option,
                    accent: accent,
                    isPicked: pickedIndex == index,
                    isDimmed: pickedIndex != nil && pickedIndex != index,
                    action: { pick(index) }
                )
            }

            Button(action: model.dismissAsk) {
                Text("ANSWER IN TERMINAL INSTEAD")
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(IslandPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .disabled(pickedIndex != nil)
            .help("Release the agent so it prompts in its own terminal")
        }
    }

    /// The pick is shown immediately and the model validates the index before it
    /// travels anywhere, so a stale card cannot answer a newer question.
    private func pick(_ index: Int) {
        guard pickedIndex == nil else { return }
        pickedIndex = index
        model.answerAsk(optionIndex: index)
    }
}

private struct AnswerOptionRow: View {
    let index: Int
    let option: PendingQuestionOption
    let accent: Color
    let isPicked: Bool
    let isDimmed: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                BandScrambleDigit(
                    digit: index + 1,
                    background: accent,
                    foreground: IslandPalette.surface
                )
                .frame(width: 16, height: 16)
                .background(accent)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(IslandPalette.text.opacity(0.92))
                        .lineLimit(1)
                    if let description = option.description {
                        Text(description)
                            .font(.system(size: 8.5))
                            .foregroundStyle(IslandPalette.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)

                if isPicked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .opacity(isDimmed ? 0.32 : 1)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.easeOut(duration: 0.18), value: isPicked)
        .accessibilityLabel("Option \(index + 1): \(option.label)")
        .accessibilityHint(option.description ?? "")
    }

    private var rowBackground: Color {
        if isPicked { return accent.opacity(0.2) }
        return isHovered ? accent.opacity(0.12) : IslandPalette.surface.opacity(0.6)
    }

    private var borderColor: Color {
        if isPicked { return accent }
        return isHovered ? accent.opacity(0.45) : .clear
    }
}
