import Foundation
import simd

/// The pointer's shape: a round drop, or an arrow made of the same liquid.
enum CursorForm: String, CaseIterable, Identifiable, Codable {
    case dot
    case arrow

    var id: Self { self }

    /// A form this version does not know, saved by a later one, reads as the arrow rather than spoiling the settings.
    init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .arrow
    }
}

/// The body's shape for one mouse function, described by numbers that can each be animated on their own: a core on
/// the pointer (a dot, or the arrow), a ring and a few limbs. Because every glyph is made of the same parts, the body
/// can flow from any one into any other, across the two forms too.
///
/// Each form has its own set for the pointer, links and the badges (copy, alias, menu, forbidden); the precise tools
/// (text, resizing, grabbing, the crosshair) are the same in both.
struct Glyph {
    /// A stroke with round ends, relative to the pointer, whose thickness can change from one end to the other.
    struct Limb {
        var start = SIMD2<Double>.zero
        var end = SIMD2<Double>.zero
        var startRadius = 0.0
        var endRadius = 0.0
    }

    private static let limbCount = 6
    /// The dot radius the shapes are drawn for. Other sizes scale them, the arrow included: it is 16 points tall at
    /// this size.
    static let designRadius = 6.5

    var core = 0.0
    /// Radius of the thick end of the tail, for the glyphs that trail.
    var tail = 0.0
    var ringCenter = SIMD2<Double>.zero
    var ringRadius = 0.0
    var ringWidth = 0.0
    var limbs = [Limb](repeating: Limb(), count: limbCount)
    /// Whether the body trails behind the pointer and bounces when pressed. Precise tools do neither.
    var isLively = false
    /// Whether the core is drawn as the arrow rather than as a round dot.
    var isArrow = false
    /// Whether the glyph shrinks to about half its size while the pointer moves slowly, as it does when aiming.
    var shrinksWhenAiming = false
    /// How much the glyph shrinks while a mouse button is held.
    var pressedScale = 0.85

    init() {}

    init(for context: CursorContext, form: CursorForm, dotRadius: Double) {
        switch form {
        case .dot: dot(for: context, r: dotRadius)
        case .arrow: arrow(for: context, r: dotRadius)
        }
    }

    private mutating func dot(for context: CursorContext, r: Double) {
        let u = r / Self.designRadius
        // The thinnest stroke that still reads at small sizes.
        let thin = max(0.9, 0.15 * r)
        switch context {
        case .pointer, .other, .hidden:
            // An app's own cursor that we do not recognize also gets the plain dot.
            core = r
            tail = r
            isLively = true
            shrinksWhenAiming = true
            pressedScale = 0.62
        case .link:
            // A small dot: precise over something to click.
            core = 0.42 * r
            tail = core
            isLively = true
            pressedScale = 0.8
        case .text(let halfHeight):
            // As tall as the app's own I-beam, which matches its text; the size setting scales it like the rest.
            bar(along: SIMD2(0, 1), halfLength: Double(halfHeight) * u, halfWidth: 1.75 * u)
        case .verticalText:
            bar(along: SIMD2(1, 0), halfLength: 9 * u, halfWidth: 1.75 * u)
        case .grab:
            // A ring with a dot in it, an open hand; `grabbing` closes the ring onto the dot.
            core = 0.42 * r
            (ringRadius, ringWidth) = (1.3 * r, 0.3 * r)
        case .grabbing:
            core = 0.85 * r
            (ringRadius, ringWidth) = (0.45 * r, 0.3 * r)
            pressedScale = 1
        case .resize(let direction, let bothWays, let divider):
            // A spindle pointing the ways the edge can go, crossed by a line when the edge is a divider.
            let way = SIMD2(Double(direction.dx), Double(direction.dy))
            let tip = max(0.65, 0.1 * r)
            core = 0.6 * r
            limbs[0] = Limb(start: .zero, end: way * 2.7 * r, startRadius: 0.55 * r, endRadius: tip)
            if bothWays {
                limbs[1] = Limb(start: .zero, end: -way * 2.7 * r, startRadius: 0.55 * r, endRadius: tip)
            }
            if divider {
                let across = SIMD2(-way.y, way.x) * 1.9 * r
                line(2, from: .zero, to: across, radius: thin)
                line(3, from: .zero, to: -across, radius: thin)
            }
        case .crosshair:
            core = thin
            for (index, way) in [SIMD2(1.0, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1)].enumerated() {
                line(index, from: way * 0.8 * r, to: way * 2.2 * r, radius: thin)
            }
        case .notAllowed:
            (ringRadius, ringWidth) = (1.35 * r, 0.34 * r)
            line(0, from: SIMD2(-0.9, 0.9) * r, to: SIMD2(0.9, -0.9) * r, radius: max(thin, 0.17 * r))
        case .copy:
            // The dot with a plus beside it.
            core = r
            plus(at: SIMD2(1.9, -1.9) * r, arm: 0.62 * r, radius: thin)
        case .alias:
            // The dot with a small arrow beside it.
            core = r
            alias(at: SIMD2(1.8, -1.8) * r, size: 0.6 * r, radius: thin)
        case .menu:
            // The dot with three lines beside it.
            core = r
            menu(at: SIMD2(1.875, -1.8) * r, halfWidth: 0.575 * r, spacing: 0.55 * r, radius: thin)
        case .zoom(let magnifies):
            lens(magnifies: magnifies, r: r, thin: thin)
        }
    }

    /// The arrow's set, drawn for `designRadius` and scaled by `u`.
    private mutating func arrow(for context: CursorContext, r: Double) {
        let u = r / Self.designRadius
        let thin = max(0.9, u)
        // Where macOS puts its badges: below and to the right of the arrow, clear of it.
        let badge = SIMD2(15.5, -18) * u
        isArrow = true
        switch context {
        case .pointer, .other, .hidden:
            core = r
            tail = r
            isLively = true
            shrinksWhenAiming = true
            pressedScale = 0.62
        case .link:
            // A smaller arrow: precise over something to click.
            core = 0.6 * r
            tail = core
            isLively = true
            pressedScale = 0.8
        case .text, .verticalText, .grab, .grabbing, .resize, .crosshair:
            // The precise tools are the dot's, in both forms.
            dot(for: context, r: r)
            isArrow = false
        case .notAllowed:
            core = r
            ringCenter = badge
            (ringRadius, ringWidth) = (4.2 * u, 1.6 * u)
            line(0, from: badge + SIMD2(-2.9, 2.9) * u, to: badge + SIMD2(2.9, -2.9) * u, radius: 0.8 * thin)
        case .copy:
            core = r
            plus(at: badge, arm: 3 * u, radius: thin)
        case .alias:
            core = r
            alias(at: badge, size: 3 * u, radius: thin)
        case .menu:
            core = r
            menu(at: badge, halfWidth: 3.2 * u, spacing: 2.8 * u, radius: thin)
        case .zoom(let magnifies):
            lens(magnifies: magnifies, r: r, thin: thin)
        }
    }

    /// The glyph as a plain list of numbers, the form in which it is animated.
    var values: [Double] {
        get {
            [core, tail, ringCenter.x, ringCenter.y, ringRadius, ringWidth]
                + limbs.flatMap { [$0.start.x, $0.start.y, $0.end.x, $0.end.y, $0.startRadius, $0.endRadius] }
        }
        set {
            (core, tail, ringRadius, ringWidth) = (newValue[0], newValue[1], newValue[4], newValue[5])
            ringCenter = SIMD2(newValue[2], newValue[3])
            for index in limbs.indices {
                let o = 6 + index * 6
                limbs[index] = Limb(start: SIMD2(newValue[o], newValue[o + 1]),
                                    end: SIMD2(newValue[o + 2], newValue[o + 3]),
                                    startRadius: newValue[o + 4], endRadius: newValue[o + 5])
            }
        }
    }

    /// The text cursor: a thin bar centered on the pointer.
    private mutating func bar(along axis: SIMD2<Double>, halfLength: Double, halfWidth: Double) {
        let reach = axis * max(halfLength - halfWidth, 0)
        core = halfWidth
        line(0, from: .zero, to: reach, radius: halfWidth)
        line(1, from: .zero, to: -reach, radius: halfWidth)
    }

    private mutating func plus(at center: SIMD2<Double>, arm: Double, radius: Double) {
        line(0, from: center - SIMD2(arm, 0), to: center + SIMD2(arm, 0), radius: radius)
        line(1, from: center - SIMD2(0, arm), to: center + SIMD2(0, arm), radius: radius)
    }

    /// A small arrow pointing up and to the right: a link to the item, rather than the item.
    private mutating func alias(at center: SIMD2<Double>, size: Double, radius: Double) {
        let tip = center + SIMD2(size, size)
        line(0, from: center - SIMD2(size, size), to: tip, radius: radius)
        line(1, from: tip, to: tip - SIMD2(1.4 * size, 0), radius: radius)
        line(2, from: tip, to: tip - SIMD2(0, 1.4 * size), radius: radius)
    }

    private mutating func menu(at center: SIMD2<Double>, halfWidth: Double, spacing: Double, radius: Double) {
        for index in 0..<3 {
            let y = center.y + spacing * Double(1 - index)
            line(index, from: SIMD2(center.x - halfWidth, y), to: SIMD2(center.x + halfWidth, y), radius: radius)
        }
    }

    /// A lens with a handle, and a minus or a plus in it.
    private mutating func lens(magnifies: Bool, r: Double, thin: Double) {
        let handle = SIMD2(1, -1) / 2.0.squareRoot()
        (ringRadius, ringWidth) = (1.4 * r, 0.3 * r)
        line(0, from: SIMD2(-0.65 * r, 0), to: SIMD2(0.65 * r, 0), radius: thin)
        if magnifies {
            line(1, from: SIMD2(0, -0.65 * r), to: SIMD2(0, 0.65 * r), radius: thin)
        }
        line(2, from: handle * 1.55 * r, to: handle * 2.7 * r, radius: max(thin, 0.24 * r))
    }

    private mutating func line(_ index: Int, from start: SIMD2<Double>, to end: SIMD2<Double>, radius: Double) {
        limbs[index] = Limb(start: start, end: end, startRadius: radius, endRadius: radius)
    }
}
