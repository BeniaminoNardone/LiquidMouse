import AppKit

/// How the body is painted. `automatic` follows the system: light on its dark appearance, dark on its light one,
/// so it stands out on what is usually around it.
enum BodyLook: String, CaseIterable, Identifiable, Codable {
    case automatic
    case dark
    case light

    var id: Self { self }

    /// A look this version does not know, saved by a later one, reads as automatic rather than spoiling the settings.
    init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .automatic
    }

    func resolved(systemIsDark: Bool) -> BodyLook {
        self == .automatic ? (systemIsDark ? .light : .dark) : self
    }

    /// The body's color, and its rim's: the opposite shade, so the body shows on content of its own shade.
    var fill: CGColor { self == .light ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.11, alpha: 1) }
    var rim: CGColor { self == .light ? CGColor(gray: 0.1, alpha: 0.85) : CGColor(gray: 1, alpha: 1) }
    var shadowOpacity: Float { self == .light ? 0.25 : 0.3 }
}

/// A transparent, click-through window covering one screen, where our cursor is drawn above everything else.
final class OverlayWindow: NSWindow {
    static let rimWidth: CGFloat = 1.25
    /// Within this distance of the pointer the body is fully opaque; beyond it the trail fades out.
    static let solidRadius: CGFloat = 24
    static let shadowRadius: CGFloat = 2.5
    /// The cursor is not quite opaque.
    static let bodyOpacity: Float = 0.94
    /// On every Space, still while they slide past, and out of the window cycle.
    private static let everySpace: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
    ]

    /// How far the body's layer reaches around the pointer: the body's own reach, plus room for its rim and shadow.
    static func extent(reach: CGFloat) -> CGFloat {
        max(reach, solidRadius) + 16
    }
    /// Layers are redrawn every frame: implicit animations would smear them.
    private static let noAnimations: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "path": NSNull(), "shadowPath": NSNull(), "hidden": NSNull(),
        "opacity": NSNull(), "locations": NSNull(),
    ]

    /// Holds the liquid body, with its origin on the pointer.
    private let bodyLayer = CALayer()
    /// A slightly larger copy of the body underneath it, in the opposite shade, so the body stays visible on content
    /// of its own shade.
    private let rimLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private let fade = CAGradientLayer()
    /// The drops of a press, painted like the body but outside it too: they fly on from where the press was, so they
    /// can end up far from the pointer.
    private let splashRimLayer = CAShapeLayer()
    private let splashFillLayer = CAShapeLayer()
    private var drawnShape: LiquidBody.Shape?
    private var drawnLook: BodyLook?
    private var drawnPosition: CGPoint?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        // The system cursor's own level, above everything: system alerts sit at the shielding level just below
        // and covered the cursor there, while the real one was hidden.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)))
        collectionBehavior = Self.everySpace

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        contentView = content

        rimLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        rimLayer.shadowRadius = Self.shadowRadius
        rimLayer.shadowOffset = CGSize(width: 0, height: -1)
        bodyLayer.opacity = Self.bodyOpacity
        fade.type = .radial
        fade.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        fade.startPoint = CGPoint(x: 0.5, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 1)

        splashRimLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        splashRimLayer.shadowRadius = Self.shadowRadius
        splashRimLayer.shadowOffset = CGSize(width: 0, height: -1)
        for layer in layers {
            layer.actions = Self.noAnimations
        }
        bodyLayer.isHidden = true
        bodyLayer.addSublayer(rimLayer)
        bodyLayer.addSublayer(fillLayer)
        bodyLayer.mask = fade
        content.layer?.addSublayer(bodyLayer)
        // Above the body, so the dot's rim does not show as a ring in the middle of the splash.
        content.layer?.addSublayer(splashRimLayer)
        content.layer?.addSublayer(splashFillLayer)
        place(on: screen)
    }

    private var layers: [CALayer] { [bodyLayer, rimLayer, fillLayer, fade, splashRimLayer, splashFillLayer] }

    /// Left out of screenshots, as the system's cursor is, but kept in recordings and screen sharing, where the
    /// system's cursor shows too.
    func setCapturable(_ capturable: Bool) {
        let sharing: NSWindow.SharingType = capturable ? .readOnly : .none
        if sharingType != sharing {
            sharingType = sharing
        }
    }

    /// Puts the window back on every Space when it is shown but missing from the current one, and returns whether
    /// it had to. macOS sometimes ties a window that joins all Spaces to a single one (seen after the screen was
    /// locked, with two desktops): the cursor was then invisible on the others. Setting the same behavior again
    /// does nothing; dropping the flag, letting WindowServer hear of it, and setting it again puts the window back.
    @discardableResult
    func rejoinEverySpace() -> Bool {
        guard isVisible, !isOnActiveSpace else { return false }
        collectionBehavior = Self.everySpace.subtracting(.canJoinAllSpaces)
        CATransaction.flush()
        collectionBehavior = Self.everySpace
        return true
    }

    /// Covers `screen`. When the screens change the windows are moved rather than made anew: making and dropping
    /// windows is costly for WindowServer, and AppKit does not always free one once it is closed.
    func place(on screen: NSScreen) {
        if frame != screen.frame {
            setFrame(screen.frame, display: false)
        }
        // Layers added by hand do not follow the screen's resolution on their own.
        for layer in layers {
            layer.contentsScale = screen.backingScaleFactor
        }
        clear()
    }

    /// Draws the body with its origin at `point`, given in global screen coordinates.
    /// `reach` is how far from the pointer the body can extend. Returns whether anything changed on screen.
    @discardableResult
    func drawBody(_ shape: LiquidBody.Shape, at point: CGPoint, reach: CGFloat, look: BodyLook) -> Bool {
        let position = pixelAligned(CGPoint(x: point.x - frame.minX, y: point.y - frame.minY))
        guard shape != drawnShape || look != drawnLook || position != drawnPosition || bodyLayer.isHidden
                || bodyLayer.bounds.width != 2 * Self.extent(reach: reach)
        else { return false }
        if look != drawnLook {
            paint(look)
        }
        let extent = Self.extent(reach: reach)
        if bodyLayer.bounds.width != 2 * extent {
            // Centring the bounds on zero puts the layer's origin, and so the shape's, on the pointer.
            bodyLayer.bounds = CGRect(x: -extent, y: -extent, width: 2 * extent, height: 2 * extent)
            fade.frame = bodyLayer.bounds
            fade.locations = [0, NSNumber(value: Double(Self.solidRadius / extent)), 1]
        }
        if shape != drawnShape {
            let rim = shape.path(grownBy: Self.rimWidth)
            rimLayer.path = rim
            rimLayer.shadowPath = rim
            fillLayer.path = shape.path(grownBy: 0)
            let splash = LiquidBody.Shape(strokes: shape.splash)
            let splashRim = splash.path(grownBy: Self.rimWidth)
            splashRimLayer.path = splashRim
            splashRimLayer.shadowPath = splashRim
            splashFillLayer.path = splash.path(grownBy: 0)
            drawnShape = shape
        }
        bodyLayer.position = position
        splashRimLayer.position = position
        splashFillLayer.position = position
        splashRimLayer.isHidden = false
        splashFillLayer.isHidden = false
        drawnPosition = position
        bodyLayer.isHidden = false
        return true
    }

    private func paint(_ look: BodyLook) {
        fillLayer.fillColor = look.fill
        rimLayer.fillColor = look.rim
        rimLayer.shadowOpacity = look.shadowOpacity
        splashFillLayer.fillColor = fillLayer.fillColor
        splashRimLayer.fillColor = rimLayer.fillColor
        splashRimLayer.shadowOpacity = rimLayer.shadowOpacity
        drawnLook = look
    }

    /// Returns whether anything changed on screen.
    @discardableResult
    func clear() -> Bool {
        guard !bodyLayer.isHidden else { return false }
        bodyLayer.isHidden = true
        splashRimLayer.isHidden = true
        splashFillLayer.isHidden = true
        return true
    }

    private func pixelAligned(_ point: CGPoint) -> CGPoint {
        let scale = backingScaleFactor
        return CGPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }
}
