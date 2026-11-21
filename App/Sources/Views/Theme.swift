import SwiftUI
import AppKit
import CoreText

// MARK: - Palette

/// The 2.0 "botanical" design system: warm paper backgrounds, forest green, sage, sand,
/// lavender and clay accents. Every colour has a light and a dark variant.
enum Theme {
    static let bg        = Color(light: 0xF4F1EA, dark: 0x1B201D)
    static let surface   = Color(light: 0xFBF9F5, dark: 0x242B27)
    static let raised    = Color(light: 0xFFFFFF, dark: 0x2C342F)
    static let sidebar   = Color(light: 0xEEEADF, dark: 0x161A18)
    static let line      = Color(light: 0xE5DFD3, dark: 0x343D37)
    static let line2     = Color(light: 0xEDE8DE, dark: 0x2E3631)
    static let ink       = Color(light: 0x23302A, dark: 0xE9EDE7)
    static let ink2      = Color(light: 0x5F6B64, dark: 0xAEB8B1)
    static let ink3      = Color(light: 0x9BA39D, dark: 0x76817A)

    static let forest    = Color(light: 0x2F4135, dark: 0x9DBB98)
    static let onForest  = Color(light: 0xF7F4EC, dark: 0x17201A)
    static let hero      = Color(light: 0x2F4135, dark: 0x2A3A2F)
    static let sage      = Color(light: 0x9FB096, dark: 0x7E9A78)
    static let sageTint  = Color(light: 0xE6ECE1, dark: 0x2B3A2E)
    static let sageInk   = Color(light: 0x4D6B4A, dark: 0xA9C6A3)
    static let sand      = Color(light: 0xEFE4D3, dark: 0x3A3226)
    static let sandInk   = Color(light: 0x8C6B44, dark: 0xD9B98E)
    static let lavender  = Color(light: 0xE7E2EC, dark: 0x332E3A)
    static let lavInk    = Color(light: 0x6C6080, dark: 0xBDB2D0)
    static let clay      = Color(light: 0xF0DDD2, dark: 0x3D2A23)
    static let clayInk   = Color(light: 0x9B4F36, dark: 0xE7A58D)

    /// A pair of fill + ink colours for tinted chips, tiles and icons.
    enum Tone: CaseIterable {
        case sage, sand, lavender, clay, neutral
        var fill: Color {
            switch self {
            case .sage: return Theme.sageTint
            case .sand: return Theme.sand
            case .lavender: return Theme.lavender
            case .clay: return Theme.clay
            case .neutral: return Theme.line2
            }
        }
        var ink: Color {
            switch self {
            case .sage: return Theme.sageInk
            case .sand: return Theme.sandInk
            case .lavender: return Theme.lavInk
            case .clay: return Theme.clayInk
            case .neutral: return Theme.ink2
            }
        }
        /// Stable tone for a name (pupil avatars).
        static func forName(_ name: String) -> Tone {
            let tones: [Tone] = [.sage, .sand, .lavender, .clay]
            let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            return tones[abs(sum) % tones.count]
        }
    }

    // MARK: Type

    /// EB Garamond (bundled, SIL Open Font License) with lining numerals; falls back to the
    /// system serif if the font could not be loaded.
    static func serif(_ size: CGFloat) -> Font {
        if let f = FontLoader.serif(size) { return Font(f as CTFont) }
        return .system(size: size, weight: .regular, design: .serif)
    }

    static let eyebrowTracking: CGFloat = 1.4

    // MARK: Motion

    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static let gentle = Animation.easeOut(duration: 0.35)
}

extension Color {
    /// A colour that follows the window's light/dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Fonts

enum FontLoader {
    static let serifName = "EBGaramond12-Regular"
    private static var registered = false

    /// Registers the bundled fonts for this process. Safe to call more than once.
    static func register() {
        guard !registered else { return }
        registered = true
        var urls = Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? []
        urls += Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts") ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func serif(_ size: CGFloat) -> NSFont? {
        register()
        // Feature 21 = number case, selector 1 = upper-case (lining) numbers.
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [[.typeIdentifier: 21, .selectorIdentifier: 1]]
        let desc = NSFontDescriptor(name: serifName, size: size).addingAttributes([.featureSettings: features])
        guard let f = NSFont(descriptor: desc, size: size), f.fontName == serifName else { return nil }
        return f
    }
}

// MARK: - Surfaces

/// The standard card: soft paper surface, generous rounding, a hairline edge and a faint shadow.
struct CardSurface: ViewModifier {
    var padding: CGFloat = 18
    var radius: CGFloat = 20
    var fill: Color = Theme.surface
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.line2))
            .shadow(color: Color.black.opacity(0.035), radius: 10, x: 0, y: 4)
    }
}

extension View {
    func cardSurface(padding: CGFloat = 18, radius: CGFloat = 20, fill: Color = Theme.surface) -> some View {
        modifier(CardSurface(padding: padding, radius: radius, fill: fill))
    }

    /// Fades and lifts the view in when it first appears. `index` staggers siblings.
    func appearIn(_ index: Int = 0) -> some View { modifier(AppearIn(delay: Double(index) * 0.05)) }

    /// Lifts slightly with a deeper shadow while the pointer is over it.
    func hoverLift(_ enabled: Bool = true) -> some View { modifier(HoverLift(enabled: enabled)) }

    /// Uppercase, tracked label used above groups ("WHO AND WHEN").
    func eyebrow() -> some View {
        self.font(.system(size: 10.5, weight: .semibold)).tracking(Theme.eyebrowTracking)
            .textCase(.uppercase).foregroundStyle(Theme.ink3)
    }
}

struct AppearIn: ViewModifier {
    var delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true; return }
                withAnimation(Theme.spring.delay(delay)) { shown = true }
            }
    }
}

struct HoverLift: ViewModifier {
    var enabled: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && enabled ? 1.012 : 1)
            .shadow(color: Color.black.opacity(hovering && enabled ? 0.07 : 0), radius: 14, x: 0, y: 8)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Buttons

/// Filled forest capsule — the main action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .padding(.horizontal, large ? 22 : 16).padding(.vertical, large ? 11 : 8)
            .foregroundStyle(Theme.onForest)
            .background(Capsule().fill(Theme.forest))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Outlined paper capsule — secondary actions.
struct SoftButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        SoftButtonBody(configuration: configuration, compact: compact)
    }
}

private struct SoftButtonBody: View {
    let configuration: ButtonStyleConfiguration
    var compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    var body: some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .padding(.horizontal, compact ? 11 : 15).padding(.vertical, compact ? 5 : 8)
            .foregroundStyle(Theme.ink)
            .background(Capsule().fill(hovering ? Theme.raised : Theme.surface))
            .overlay(Capsule().strokeBorder(Theme.line))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hovering = $0 }
            .contentShape(Capsule())
    }
}

/// Square icon button on a paper tile.
struct IconTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.line2))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryLarge: PrimaryButtonStyle { PrimaryButtonStyle(large: true) }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
    static var softCompact: SoftButtonStyle { SoftButtonStyle(compact: true) }
}

extension ButtonStyle where Self == IconTileButtonStyle {
    static var iconTile: IconTileButtonStyle { IconTileButtonStyle() }
}

// MARK: - Small pieces

/// Rounded tinted label: "Transcribing", "Awaiting approval", "3 added".
struct Pill: View {
    var text: String
    var tone: Theme.Tone = .sage
    var icon: String?
    var dot = false
    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(tone.ink).frame(width: 6, height: 6) }
            if let icon { Image(systemName: icon).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 9).padding(.vertical, 3.5)
        .background(Capsule().fill(tone.fill))
        .foregroundStyle(tone.ink)
    }
}

/// Initials in a tinted circle.
struct Avatar: View {
    var name: String
    var size: CGFloat = 36
    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
    var body: some View {
        let tone = Theme.Tone.forName(name)
        Text(initials)
            .font(.system(size: size * 0.34, weight: .semibold))
            .foregroundStyle(tone.ink)
            .frame(width: size, height: size)
            .background(Circle().fill(tone.fill))
    }
}

/// An SF Symbol in a soft rounded square.
struct IconBadge: View {
    var systemName: String
    var tone: Theme.Tone = .sage
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(tone.ink)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.32, style: .continuous).fill(tone.fill))
    }
}

/// Thin rounded progress bar that animates to its value.
struct SoftBar: View {
    var value: Double
    var tint: Color = Theme.sage
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line2)
                Capsule().fill(tint).frame(width: max(height, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(Theme.gentle, value: value)
    }
}

/// Ring gauge (OpenAI allowance, storage).
struct Ring: View {
    var value: Double
    var tint: Color
    var lineWidth: CGFloat
    @State private var drawn = 0.0
    init(value: Double, tint: Color = Theme.sage, lineWidth: CGFloat = 10) {
        self.value = value
        self.tint = tint
        self.lineWidth = lineWidth
    }
    var body: some View {
        ZStack {
            Circle().stroke(Theme.line2, lineWidth: lineWidth)
            Circle().trim(from: 0, to: drawn)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear { withAnimation(.easeOut(duration: 0.9).delay(0.15)) { drawn = min(max(value, 0), 1) } }
        .onChange(of: value) { _, v in withAnimation(Theme.gentle) { drawn = min(max(v, 0), 1) } }
    }
}

/// Card header: tinted icon, serif title, optional trailing content.
struct CardHeader<Trailing: View>: View {
    var title: String
    var systemImage: String?
    var tone: Theme.Tone = .sage
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 10) {
            if let systemImage { IconBadge(systemName: systemImage, tone: tone, size: 30) }
            Text(title).font(Theme.serif(20)).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, systemImage: String? = nil, tone: Theme.Tone = .sage) {
        self.init(title: title, systemImage: systemImage, tone: tone) { EmptyView() }
    }
}

/// Screen title block: serif heading with an optional line underneath.
struct ScreenTitle: View {
    var title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.serif(34)).foregroundStyle(Theme.ink)
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.ink2) }
        }
    }
}

/// The app icon (logo B: a page with a sprig) at any size.
struct AppLogo: View {
    var size: CGFloat = 36
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
    }
}

// MARK: - Illustrations

/// Layered hills with a low sun — the hero and video-thumbnail artwork.
struct HillsArt: View {
    var dark = false
    var sun = true
    var body: some View {
        Canvas { ctx, size in
            // Drawn in a 400 x 260 space, scaled to fill.
            let s = max(size.width / 400, size.height / 260)
            let dx = (size.width - 400 * s) / 2, dy = (size.height - 260 * s) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: dx + x * s, y: dy + y * s) }
            let base: UInt32 = dark ? 0x3E5446 : 0xE7ECE2
            let layers: [UInt32] = dark ? [0x56705C, 0x6E8873, 0x89A08B, 0xA9BBA7] : [0xB9C7B2, 0xA2B49B, 0x8CA185, 0x738B6E]
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: NSColor(hex: base))))
            if sun {
                let r = 34 * s, c = p(285, 92)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(Color(nsColor: NSColor(hex: dark ? 0xE9DFC8 : 0xF1E7D4, alpha: dark ? 0.85 : 1))))
            }
            // Each hill: start, then cubic segments (c1, c2, end).
            let hills: [(CGFloat, [(CGPoint, CGPoint, CGPoint)])] = [
                (150, [(CGPoint(x: 60, y: 120), CGPoint(x: 110, y: 128), CGPoint(x: 160, y: 140)),
                       (CGPoint(x: 210, y: 152), CGPoint(x: 260, y: 112), CGPoint(x: 320, y: 124)),
                       (CGPoint(x: 380, y: 136), CGPoint(x: 380, y: 140), CGPoint(x: 400, y: 132))]),
                (182, [(CGPoint(x: 70, y: 156), CGPoint(x: 120, y: 170), CGPoint(x: 190, y: 166)),
                       (CGPoint(x: 260, y: 162), CGPoint(x: 300, y: 140), CGPoint(x: 400, y: 160))]),
                (212, [(CGPoint(x: 80, y: 190), CGPoint(x: 150, y: 204), CGPoint(x: 220, y: 196)),
                       (CGPoint(x: 290, y: 188), CGPoint(x: 330, y: 184), CGPoint(x: 400, y: 198))]),
                (240, [(CGPoint(x: 90, y: 222), CGPoint(x: 170, y: 236), CGPoint(x: 250, y: 228)),
                       (CGPoint(x: 330, y: 220), CGPoint(x: 350, y: 222), CGPoint(x: 400, y: 230))]),
            ]
            for (i, hill) in hills.enumerated() {
                var path = Path()
                path.move(to: p(0, hill.0))
                for seg in hill.1 { path.addCurve(to: p(seg.2.x, seg.2.y), control1: p(seg.0.x, seg.0.y), control2: p(seg.1.x, seg.1.y)) }
                path.addLine(to: p(400, 260 + 40))
                path.addLine(to: p(0, 260 + 40))
                path.closeSubpath()
                ctx.fill(path, with: .color(Color(nsColor: NSColor(hex: layers[i], alpha: i == 0 ? 0.9 : 1))))
            }
        }
    }
}

/// A small leaf sprig drawn in one colour (greeting decoration, empty states).
struct Sprig: View {
    var color: Color = Theme.forest
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 120
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            var stem = Path()
            stem.move(to: p(30, 102))
            stem.addCurve(to: p(88, 20), control1: p(48, 80), control2: p(64, 58))
            ctx.stroke(stem, with: .color(color), style: StrokeStyle(lineWidth: 2.6 * s, lineCap: .round))
            let leaves: [(CGFloat, CGFloat, Double)] = [(44, 82, -38), (56, 66, -30), (67, 50, -26), (78, 34, -20)]
            for (x, y, a) in leaves {
                var left = Path()
                left.move(to: p(x, y))
                left.addCurve(to: p(x - 20, y - 26), control1: p(x - 14, y - 4), control2: p(x - 22, y - 14))
                left.addCurve(to: p(x, y), control1: p(x - 8, y - 24), control2: p(x, y - 14))
                let t = CGAffineTransform(translationX: x * s, y: y * s).rotated(by: a * .pi / 180).translatedBy(x: -x * s, y: -y * s)
                ctx.fill(left.applying(t), with: .color(color))
                var right = Path()
                right.move(to: p(x + 4, y - 2))
                right.addCurve(to: p(x + 30, y - 24), control1: p(x + 18, y - 4), control2: p(x + 28, y - 12))
                right.addCurve(to: p(x + 4, y - 2), control1: p(x + 18, y - 24), control2: p(x + 8, y - 16))
                ctx.fill(right, with: .color(color.opacity(0.85)))
            }
        }
    }
}

// MARK: - Toasts

/// A short message that slides up from the bottom of the main window.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String
    var lessonId: UUID?
}

struct ToastView: View {
    var toast: Toast
    var onView: (() -> Void)?
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(nsColor: NSColor(hex: 0xCFE0C6)))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.system(size: 13, weight: .semibold))
                Text(toast.detail).font(.system(size: 12)).opacity(0.75)
            }
            if let onView {
                Button("View", action: onView).buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: NSColor(hex: 0xCFE0C6)))
                    .padding(.leading, 10)
            }
        }
        .foregroundStyle(Color(nsColor: NSColor(hex: 0xF3EFE5)))
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(nsColor: NSColor(hex: 0x2F4135))))
        .shadow(color: .black.opacity(0.22), radius: 17, x: 0, y: 14)
    }
}

// MARK: - Flow layout

/// Wraps pills onto as many lines as they need.
struct FlowPills<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content
    var body: some View { FlowLayout(spacing: spacing) { content } }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}
