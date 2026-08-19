import SwiftUI

enum Brand {
    static let yellow      = Color(hex: 0xFFC700)
    static let yellowDeep  = Color(hex: 0xE0A800)
    static let yellowSoft  = Color(hex: 0xFFF6D6)
    static let ink         = Color(hex: 0x191919)
    static let page        = Color(hex: 0xFAFAF8)
    static let card        = Color.white
    static let line        = Color(hex: 0xE4E2DC)
    static let lineSoft    = Color(hex: 0xF0EEE9)
    static let muted       = Color(hex: 0x78766E)
    static let studOff     = Color(hex: 0xDEDCD4)
    static let whatsApp    = Color(hex: 0x25D366)

    /// A brick's colour is decided by its theme, so Star Wars is always the same blue
    /// and Botanicals always the same green. Same seed as `BrickArt`, so a theme's
    /// tile and its artwork match.
    static func themeColor(_ theme: String,
                           saturation: Double = 0.34,
                           brightness: Double = 0.88) -> Color {
        Color(hue: Double(Catalog.themeSeed(theme) % 360) / 360,
              saturation: saturation, brightness: brightness)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255
        )
    }
}

extension Font {
    /// Set numbers are identifiers, not prose. Monospacing them makes them scannable
    /// and stops "10305" reading like a price.
    static func setNumber(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    static func priceValue(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}

// MARK: - Brick shapes

/// The row of studs that sits on top of a brick.
///
/// Seen from the front a stud is not a circle — it is a short rounded-top cylinder,
/// which is why these are squared off at the bottom where they meet the brick.
struct StudCaps: View {
    var count: Int = 4
    var color: Color = Brand.yellow
    var studWidth: CGFloat = 15
    var studHeight: CGFloat = 6

    var body: some View {
        // Intrinsically sized: a stack centres it, a leading frame aligns it left.
        // Nothing has to fight a maxWidth to place it.
        HStack(spacing: studWidth * 0.62) {
            ForEach(0..<max(count, 1), id: \.self) { _ in
                UnevenRoundedRectangle(
                    topLeadingRadius: studWidth * 0.32,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: studWidth * 0.32
                )
                .fill(color)
                .frame(width: studWidth, height: studHeight)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A moulded brick face: the colour, plus a darker lip along the bottom where the
/// plastic turns under. It is a 3pt detail and it is most of why something reads as a
/// brick rather than a rounded rectangle.
struct BrickFace: Shape {
    var cornerRadius: CGFloat = 8
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: cornerRadius)
    }
}

extension View {
    func brickBody(_ color: Color, cornerRadius: CGFloat = 8, lip: CGFloat = 3) -> some View {
        background(
            ZStack(alignment: .bottom) {
                BrickFace(cornerRadius: cornerRadius)
                    .fill(color)
                    .overlay(BrickFace(cornerRadius: cornerRadius).fill(.black.opacity(0.20)))
                BrickFace(cornerRadius: cornerRadius)
                    .fill(color)
                    .padding(.bottom, lip)
            }
        )
    }
}

// MARK: - Completeness meter

/// The one element the app is remembered by. Completeness is the single biggest
/// source of disputes in used LEGO, so it appears on every card rather than being
/// buried in a description.
struct StudMeter: View {
    let filled: Int
    var total: Int = 8
    var size: CGFloat = 9
    var showLabel: Bool = false

    private var label: String {
        switch filled {
        case 8: "Complete"
        case 7: "Near complete"
        case 5...6: "Some pieces missing"
        default: "Partial"
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: 3) {
                ForEach(0..<total, id: \.self) { index in
                    Circle()
                        .fill(index < filled ? Brand.yellow : Brand.studOff)
                        .frame(width: size, height: size)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Completeness \(filled) of \(total). \(label).")

            if showLabel {
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Brand.muted)
            }
        }
    }
}

// MARK: - Reusable chrome

struct Chip: View {
    let title: String
    let isSelected: Bool
    var accent: Color = Brand.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? (accent == Brand.yellow ? Brand.ink : .white) : Brand.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 6.5)
                .background {
                    if isSelected {
                        // Selected chips are pressed-in tiles: the lip reads as depth.
                        BrickFace(cornerRadius: 5).fill(accent)
                    } else {
                        BrickFace(cornerRadius: 5).fill(Brand.card)
                    }
                }
                .overlay(
                    BrickFace(cornerRadius: 5)
                        .stroke(isSelected ? accent : Brand.line, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// A 2x4 brick you can press.
struct PrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    private var faceColor: Color { enabled ? Brand.yellow : Brand.line }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                StudCaps(count: 4, color: faceColor, studWidth: 17, studHeight: 7)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(enabled ? Brand.ink : Brand.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .brickBody(faceColor, cornerRadius: 8, lip: 4)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct SectionLabel: View {
    let text: String
    var studs: Int = 2

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<studs, id: \.self) { _ in
                    Circle().fill(Brand.yellow).frame(width: 5, height: 5)
                }
            }
            .accessibilityHidden(true)

            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Brand.muted)
        }
    }
}

// MARK: - Theme brick

/// A category, as an actual brick. This is where categories live now that they are off
/// the front screen, so they may as well be the most LEGO thing in the app.
struct ThemeBrick: View {
    let name: String
    let listingCount: Int
    let action: () -> Void

    private var face: Color { Brand.themeColor(name) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                StudCaps(count: 3, color: face, studWidth: 15, studHeight: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Brand.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(listingCount > 0
                         ? "\(listingCount) listing\(listingCount == 1 ? "" : "s")"
                         : "None yet")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Brand.ink.opacity(0.55))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 11)
                .brickBody(face, cornerRadius: 7, lip: 3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(listingCount) listings")
    }
}

/// Placeholder artwork until real photos load. Deterministic from the theme so a
/// given theme always looks the same.
struct BrickArt: View {
    let seed: Int
    var height: CGFloat = 132

    var body: some View {
        let hue = Double(seed % 360) / 360

        Canvas { context, size in
            var generator = SeededGenerator(seed: UInt64(seed) &+ 7)
            let columns = 10
            let rows = 4
            let unit = size.width / CGFloat(columns)
            let brickHeight = size.height / CGFloat(rows + 1)

            for row in 0..<rows {
                var x = 0
                while x < columns {
                    let width = min(2 + Int(generator.next() % 3), columns - x)
                    let lightness = 0.46 + Double(generator.next() % 32) / 100
                    let color = Color(hue: hue, saturation: 0.42, brightness: lightness)

                    let rect = CGRect(
                        x: CGFloat(x) * unit + 1,
                        y: CGFloat(row) * brickHeight + brickHeight * 0.55,
                        width: CGFloat(width) * unit - 2,
                        height: brickHeight * 0.8
                    )
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))

                    for stud in 0..<width {
                        let studRect = CGRect(
                            x: CGFloat(x + stud) * unit + unit * 0.3,
                            y: rect.minY - brickHeight * 0.18,
                            width: unit * 0.4,
                            height: brickHeight * 0.2
                        )
                        context.fill(Path(roundedRect: studRect, cornerRadius: 1), with: .color(color))
                    }
                    x += width
                }
            }
        }
        .frame(height: height)
        .background(Color(hue: hue, saturation: 0.16, brightness: 0.95))
        .accessibilityHidden(true)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 2862933555777941757 &+ 3037000493 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 16
    }
}
