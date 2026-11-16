import AppKit
import SwiftUI

/// Draws every shape of both forms next to the macOS cursor it stands for, into a PNG: `--gallery <file>`.
/// The shapes come from the same code that draws the cursor, at rest and while moving.
enum Gallery {
    private struct Row {
        let title: String
        let cursor: NSCursor
        /// Over a button found through the Accessibility API, where apps keep the standard arrow.
        var overButton = false
    }

    private static let rows: [Row] = [
        Row(title: "Pointer", cursor: .arrow),
        Row(title: "Button (Accessibility)", cursor: .arrow, overButton: true),
        Row(title: "Link", cursor: .pointingHand),
        Row(title: "Text", cursor: .iBeam),
        Row(title: "Vertical text", cursor: .iBeamCursorForVerticalLayout),
        Row(title: "Grab", cursor: .openHand),
        Row(title: "Grabbing", cursor: .closedHand),
        Row(title: "Resize column", cursor: .columnResize),
        Row(title: "Resize row, up", cursor: .rowResize(directions: .up)),
        Row(title: "Window edge", cursor: .frameResize(position: .right, directions: .all)),
        Row(title: "Window corner", cursor: .frameResize(position: .topLeft, directions: .all)),
        Row(title: "Crosshair", cursor: .crosshair),
        Row(title: "Not allowed", cursor: .operationNotAllowed),
        Row(title: "Copy", cursor: .dragCopy),
        Row(title: "Alias", cursor: .dragLink),
        Row(title: "Contextual menu", cursor: .contextualMenu),
        Row(title: "Zoom in", cursor: .zoomIn),
        Row(title: "Zoom out", cursor: .zoomOut),
        Row(title: "An app's own cursor", cursor: .disappearingItem),
    ]

    private static let titleWidth: CGFloat = 190
    private static let cell: CGFloat = 76
    private static let movingCell: CGFloat = 230
    private static let header: CGFloat = 44
    private static let pixelScale: CGFloat = 2

    static func render(to url: URL) {
        let columns: [(title: String, width: CGFloat)] = [
            ("macOS", cell), ("Dot", cell), ("Dot, moving", movingCell), ("Arrow", cell),
            ("Arrow, moving", movingCell),
        ]
        let width = titleWidth + columns.reduce(0) { $0 + $1.width }
        let height = header + cell * CGFloat(rows.count)
        guard let context = CGContext(data: nil, width: Int(width * pixelScale), height: Int(height * pixelScale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        // Laid out from the top-left corner, y down, in points.
        context.scaleBy(x: pixelScale, y: pixelScale)
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let reader = CursorReader(scale: pixelScale)
        let look = BodyLook.dark
        var x = titleWidth
        for column in columns {
            label(column.title, at: CGPoint(x: x + 8, y: 14), bold: true)
            x += column.width
        }
        for (index, row) in rows.enumerated() {
            let top = header + cell * CGFloat(index)
            context.setFillColor(CGColor(gray: index.isMultiple(of: 2) ? 0.93 : 0.89, alpha: 1))
            context.fill(CGRect(x: 0, y: top, width: width, height: cell))
            label(row.title, at: CGPoint(x: 12, y: top + cell / 2 - 8), bold: false)
            var read = reader.read(row.cursor)?.context ?? .other
            if read == .pointer, row.overButton {
                read = .link
            }
            // Every cell puts the hot spot at the same place, so the shapes can be compared point for point.
            let hotSpot = { (left: CGFloat) in CGPoint(x: left + 32, y: top + cell / 2 - 6) }
            var left = titleWidth
            draw(row.cursor, hotSpot: hotSpot(left))
            left += cell
            for form in [CursorForm.dot, .arrow] {
                if read == .other {
                    draw(row.cursor, hotSpot: hotSpot(left))
                } else {
                    drawBody(atRest(context: read, form: form), look: look, hotSpot: hotSpot(left), in: context)
                }
                left += cell
                if read == .other {
                    draw(row.cursor, hotSpot: hotSpot(left + 8))
                } else {
                    drawBody(moving(context: read, form: form), look: look, hotSpot: hotSpot(left + 8), in: context)
                }
                left += movingCell
            }
        }
        NSGraphicsContext.current = nil
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// The app's icon, 1024 pixels square, on the rounded square every macOS icon sits in.
    static func renderIcon(to url: URL) {
        let size = 1024
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        // Laid out from the top-left corner, y down, like Apple's icon grid: an 824-pixel square 100 pixels in.
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
        let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185,
                          cornerHeight: 185, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
        context.addPath(tile)
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(tile)
        context.clip()
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.91, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
        }
        let points = Drop.outline(radius: 132, steps: 160)
        // Centered by eye: a little up and left of the middle of its box, where its weight is.
        let box = CGRect(x: points.map(\.x).min()!, y: 0, width: 0, height: 0)
            .union(CGRect(x: points.map(\.x).max()!, y: points.map(\.y).max()!, width: 0, height: 0))
        let offset = CGPoint(x: 512 - box.midX - 6, y: 512 - box.midY + 4)
        let drop = CGMutablePath()
        drop.addLines(between: points.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) })
        drop.closeSubpath()
        let look = BodyLook.dark
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 32, color: CGColor(gray: 0, alpha: 0.24))
        context.addPath(drop)
        context.setLineWidth(22)
        context.setLineJoin(.round)
        context.setStrokeColor(look.rim)
        context.setFillColor(look.rim)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
        // The tip just softened, as the cursor's is.
        context.addPath(drop)
        context.setLineWidth(6)
        context.setLineJoin(.round)
        context.setStrokeColor(look.fill)
        context.setFillColor(look.fill)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// The settings panel as it is drawn, into a PNG: `--settings <file>`. Add `-AppleLanguages '(it)'` to see it in
    /// another language.
    static func renderSettings(to url: URL) {
        let engine = Engine()
        // The panel turns the engine on; here it must leave the user's cursor alone.
        engine.hidesSystemCursor = false
        let hosting = NSHostingView(rootView: SettingsView(model: SettingsModel(engine: engine)))
        hosting.frame.size = hosting.fittingSize
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        try? image.representation(using: .png, properties: [:])?.write(to: url)
        engine.isEnabled = false
    }

    private static func tuning(_ form: CursorForm) -> LiquidBody.Tuning {
        var tuning = LiquidBody.Tuning()
        tuning.form = form
        tuning.splashes = false
        return tuning
    }

    private static func atRest(context: CursorContext, form: CursorForm) -> LiquidBody.Shape {
        var body = LiquidBody(at: .zero)
        body.tuning = tuning(form)
        body.step(to: .zero, dt: 0, context: context, pressed: false, present: true)
        for _ in 0..<240 {
            body.step(to: .zero, dt: 1.0 / 120, context: context, pressed: false, present: true)
        }
        return body.shape
    }

    /// Mid-way through a quick move to the left and a little up, the tail out behind.
    private static func moving(context: CursorContext, form: CursorForm) -> LiquidBody.Shape {
        var body = LiquidBody(at: .zero)
        body.tuning = tuning(form)
        var point = SIMD2<Double>(0, 0)
        body.step(to: point, dt: 0, context: context, pressed: false, present: true)
        for _ in 0..<240 {
            body.step(to: point, dt: 1.0 / 120, context: context, pressed: false, present: true)
        }
        let velocity = SIMD2<Double>(-900, 220)
        for _ in 0..<30 {
            point += velocity / 120
            body.step(to: point, dt: 1.0 / 120, context: context, pressed: false, present: true)
        }
        return body.shape
    }

    private static func draw(_ cursor: NSCursor, hotSpot: CGPoint) {
        let size = cursor.image.size
        let rect = CGRect(x: hotSpot.x - cursor.hotSpot.x, y: hotSpot.y - cursor.hotSpot.y, width: size.width,
                          height: size.height)
        cursor.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                          hints: nil)
    }

    /// Paints the body as the overlay does: the rim with its shadow under the body, the tail fading out.
    /// `pixelsPerPoint` sizes the shadow, which does not scale with the drawing.
    static func drawBody(_ shape: LiquidBody.Shape, look: BodyLook, hotSpot: CGPoint, in context: CGContext,
                         pixelsPerPoint: CGFloat = pixelScale) {
        context.saveGState()
        context.translateBy(x: hotSpot.x, y: hotSpot.y)
        // The shapes have y up.
        context.scaleBy(x: 1, y: -1)
        let reach = CGFloat(LiquidBody.Tuning().reach)
        let extent = OverlayWindow.extent(reach: reach)
        // The overlay's body layer is not quite opaque.
        context.setAlpha(CGFloat(OverlayWindow.bodyOpacity))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        paint(LiquidBody.Shape(strokes: shape.strokes, rings: shape.rings, outline: shape.outline), look: look,
              in: context, pixelsPerPoint: pixelsPerPoint)
        // The fade, as the overlay's radial mask: solid near the pointer, gone at the edge of the body's reach.
        context.setBlendMode(.destinationIn)
        let colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray
        let locations: [CGFloat] = [0, OverlayWindow.solidRadius / extent, 1]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                     locations: locations) {
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero,
                                       endRadius: extent, options: [])
        }
        context.endTransparencyLayer()
        context.setAlpha(1)
        paint(LiquidBody.Shape(strokes: shape.splash), look: look, in: context, pixelsPerPoint: pixelsPerPoint)
        context.restoreGState()
    }

    private static func paint(_ shape: LiquidBody.Shape, look: BodyLook, in context: CGContext,
                              pixelsPerPoint: CGFloat) {
        guard !shape.isEmpty else { return }
        context.saveGState()
        // Shadow offsets are not flipped with the drawing: down is down in the image's own space.
        context.setShadow(offset: CGSize(width: 0, height: -pixelsPerPoint),
                          blur: pixelsPerPoint * OverlayWindow.shadowRadius,
                          color: CGColor(gray: 0, alpha: CGFloat(look.shadowOpacity)))
        context.addPath(shape.path(grownBy: OverlayWindow.rimWidth))
        context.setFillColor(look.rim)
        context.fillPath()
        context.restoreGState()
        context.addPath(shape.path(grownBy: 0))
        context.setFillColor(look.fill)
        context.fillPath()
    }

    private static func label(_ text: String, at point: CGPoint, bold: Bool) {
        let font = bold ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 12)
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: NSColor.black])
    }
}
