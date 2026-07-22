import SwiftUI

/// Tiny hand-set bitmaps for the mascot's expression badges.
///
/// The mascots are sprites, so a smooth font glyph in a rounded capsule sitting
/// beside one reads as two different art styles pasted together. These are drawn
/// as square cells on the same grid the sprites use.
enum PixelGlyphs {
    /// `#` is a lit cell. Written as strings because a bitmap is easier to
    /// review — and to fix — when it looks like the thing it draws.
    static let question = [
        ".###.",
        "#...#",
        "....#",
        "...#.",
        "..#..",
        ".....",
        "..#..",
    ]

    static let check = [
        "......#",
        ".....#.",
        "#...#..",
        ".#.#...",
        "..#....",
    ]

    static let sleep = [
        "#####",
        "...#.",
        "..#..",
        ".#...",
        "#####",
    ]

    static let ellipsis = [
        "#.#.#",
    ]

    /// A bitmap is usable only if it is rectangular and made of the two symbols
    /// the renderer understands.
    static func isWellFormed(_ rows: [String]) -> Bool {
        guard let width = rows.first?.count, width > 0, !rows.isEmpty else { return false }
        return rows.allSatisfy { row in
            row.count == width && row.allSatisfy { $0 == "#" || $0 == "." }
        }
    }
}

/// Draws a bitmap as hard square cells.
///
/// One `Canvas` pass rather than a grid of shapes: this sits next to the mascot
/// in every session row, so the cost is paid per row on screen.
struct PixelGlyph: View {
    let rows: [String]
    let color: Color
    /// Offset one cell down-right behind the glyph, the way sprite work fakes an
    /// outline. Keeps the badge legible on both the panel and the notch.
    var shadow: Color? = Color.black.opacity(0.55)
    /// Side length of one cell, in points. Rounded to a whole number by the
    /// caller so cells stay square and crisp.
    let cell: CGFloat

    private var columns: Int { rows.first?.count ?? 0 }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            if let shadow {
                draw(in: &context, color: shadow, dx: cell, dy: cell)
            }
            draw(in: &context, color: color, dx: 0, dy: 0)
        }
        .frame(
            width: CGFloat(columns) * cell + (shadow == nil ? 0 : cell),
            height: CGFloat(rows.count) * cell + (shadow == nil ? 0 : cell)
        )
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, color: Color, dx: CGFloat, dy: CGFloat) {
        for (y, row) in rows.enumerated() {
            for (x, symbol) in row.enumerated() where symbol == "#" {
                context.fill(
                    Path(CGRect(
                        x: CGFloat(x) * cell + dx,
                        y: CGFloat(y) * cell + dy,
                        width: cell,
                        height: cell)),
                    with: .color(color))
            }
        }
    }
}

/// Cell size for a badge that should read at roughly `fraction` of the mascot.
///
/// Rounded to whole points and floored at 1: a fractional cell is exactly what
/// turns pixel art back into a blurry smudge.
func pixelCellSize(mascotSize: CGFloat, rowCount: Int, fraction: CGFloat = 0.42) -> CGFloat {
    guard rowCount > 0 else { return 1 }
    return max(1, ((mascotSize * fraction) / CGFloat(rowCount)).rounded())
}
