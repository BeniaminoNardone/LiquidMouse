import AppKit

/// What the mouse is about to do, judged from the cursor the frontmost app asked the system for.
enum CursorContext: Equatable {
    /// The standard arrow: nothing special under the pointer.
    case pointer
    /// Editable or selectable text. `halfHeight` is half the height of the app's I-beam, in points.
    case text(halfHeight: CGFloat)
    /// Text laid out vertically, where the I-beam lies on its side.
    case verticalText
    /// Something clickable, such as a link.
    case link
    /// Something that can be dragged around, and the same thing while it is held.
    case grab
    case grabbing
    /// An edge that can be dragged. `direction` is a unit vector with y up. When `bothWays` is false the edge
    /// only moves that way. `divider` tells a split between two panes from the edge of a window.
    case resize(direction: CGVector, bothWays: Bool, divider: Bool)
    case crosshair
    case notAllowed
    /// Dropping here makes a copy, or an alias.
    case copy
    case alias
    /// A contextual menu is available.
    case menu
    case zoom(magnifies: Bool)
    /// A cursor we have no shape for, typically one an app drew itself.
    case other
    /// An invisible cursor: the app wants the pointer out of sight.
    case hidden
}

/// Reads the system cursor and recognizes it by its pixels, the only thing the system exposes about it.
struct CursorReader {
    /// What a cursor means, with a short description of it for reports.
    struct Reading {
        let context: CursorContext
        let description: String
        /// The description without the pixels, which change with every frame of an animated cursor.
        let kind: String
    }

    private struct Pixels {
        let hash: UInt64
        /// The box around the visible pixels, in points from the image's top-left corner.
        let visible: CGRect
    }

    private struct Signature: Hashable {
        let pixels: UInt64
        let x: CGFloat
        let y: CGFloat

        init(_ pixels: Pixels, hotSpot: CGPoint) {
            self.pixels = pixels.hash
            x = hotSpot.x
            y = hotSpot.y
        }
    }

    private let scale: CGFloat
    private let iBeam: Signature?
    /// Both pixels and hot spot must match: changing the click point makes a cursor a different tool.
    private let known: [Signature: CursorContext]

    init(scale: CGFloat) {
        self.scale = scale
        iBeam = Self.pixels(of: .iBeam, scale: scale).map { Signature($0, hotSpot: NSCursor.iBeam.hotSpot) }

        var cursors: [(NSCursor, CursorContext)] = [
            (.arrow, .pointer), (.pointingHand, .link), (.openHand, .grab), (.closedHand, .grabbing),
            (.crosshair, .crosshair), (.operationNotAllowed, .notAllowed), (.dragCopy, .copy), (.dragLink, .alias),
            (.contextualMenu, .menu), (.zoomIn, .zoom(magnifies: true)), (.zoomOut, .zoom(magnifies: false)),
            (.iBeamCursorForVerticalLayout, .verticalText),
        ]
        func resize(_ dx: CGFloat, _ dy: CGFloat, bothWays: Bool, divider: Bool) -> CursorContext {
            let length = (dx * dx + dy * dy).squareRoot()
            return .resize(direction: CGVector(dx: dx / length, dy: dy / length), bothWays: bothWays, divider: divider)
        }
        cursors += [
            (.columnResize, resize(1, 0, bothWays: true, divider: true)),
            (.columnResize(directions: .right), resize(1, 0, bothWays: false, divider: true)),
            (.columnResize(directions: .left), resize(-1, 0, bothWays: false, divider: true)),
            (.rowResize, resize(0, 1, bothWays: true, divider: true)),
            (.rowResize(directions: .up), resize(0, 1, bothWays: false, divider: true)),
            (.rowResize(directions: .down), resize(0, -1, bothWays: false, divider: true)),
        ]
        // Window edges and corners, with the direction that points away from the window.
        let edges: [(NSCursor.FrameResizePosition, CGFloat, CGFloat)] = [
            (.right, 1, 0), (.left, -1, 0), (.top, 0, 1), (.bottom, 0, -1),
            (.topRight, 1, 1), (.topLeft, -1, 1), (.bottomRight, 1, -1), (.bottomLeft, -1, -1),
        ]
        for (position, dx, dy) in edges {
            cursors += [
                (.frameResize(position: position, directions: .all), resize(dx, dy, bothWays: true, divider: false)),
                (.frameResize(position: position, directions: .outward),
                 resize(dx, dy, bothWays: false, divider: false)),
                (.frameResize(position: position, directions: .inward),
                 resize(-dx, -dy, bothWays: false, divider: false)),
            ]
        }

        var known: [Signature: CursorContext] = [:]
        for (cursor, context) in cursors {
            guard let pixels = Self.pixels(of: cursor, scale: scale) else { continue }
            let signature = Signature(pixels, hotSpot: cursor.hotSpot)
            if known[signature] == nil { known[signature] = context }
        }
        self.known = known
    }

    /// The cursor the system is showing, or would show if it were not hidden.
    func read() -> Reading? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        return read(cursor)
    }

    func read(_ cursor: NSCursor) -> Reading? {
        guard cursor.hotSpot.x.isFinite, cursor.hotSpot.y.isFinite,
              let pixels = Self.pixels(of: cursor, scale: scale) else { return nil }
        let size = cursor.image.size
        let kind = String(format: "%.0fx%.0f pt, hot spot %.0f,%.0f",
                          size.width, size.height, cursor.hotSpot.x, cursor.hotSpot.y)
        let context = pixels.visible.isEmpty ? .hidden : context(of: pixels, hotSpot: cursor.hotSpot)
        return Reading(context: context, description: "\(kind), pixels \(String(pixels.hash, radix: 16))",
                       kind: kind)
    }

    private func context(of pixels: Pixels, hotSpot: CGPoint) -> CursorContext {
        let signature = Signature(pixels, hotSpot: hotSpot)
        if let context = known[signature] {
            return context
        }
        // A familiar image with a different click point must not fall through to the I-beam heuristic.
        if known.keys.contains(where: { $0.pixels == pixels.hash })
            || (iBeam?.pixels == pixels.hash && signature != iBeam) { return .other }
        // Browsers and editors often draw their own I-beam. Accept anything tall, thin and held by its middle.
        let box = pixels.visible
        let looksLikeIBeam = box.height >= 12 && box.width <= box.height * 0.6
            && abs(hotSpot.x - box.midX) <= box.width / 4 && abs(hotSpot.y - box.midY) <= box.height / 4
        guard signature == iBeam || looksLikeIBeam else { return .other }
        // Half the I-beam's height, kept within sizes that still read as a text cursor.
        return .text(halfHeight: min(max(box.height / 2, 7), 16))
    }

    private static func pixels(of cursor: NSCursor, scale: CGFloat) -> Pixels? {
        let size = cursor.image.size
        let pixelWidth = (size.width * scale).rounded(.up)
        let pixelHeight = (size.height * scale).rounded(.up)
        guard scale.isFinite, scale > 0, pixelWidth.isFinite, pixelHeight.isFinite,
              (1...1024).contains(pixelWidth), (1...1024).contains(pixelHeight) else { return nil }
        let width = Int(pixelWidth)
        let height = Int(pixelHeight)

        // Prefer the representation drawn for this exact pixel size, so the same cursor always hashes the same.
        let exact = cursor.image.representations.first { $0.pixelsWide == width && $0.pixelsHigh == height }
        var proposed = CGRect(x: 0, y: 0, width: width, height: height)
        guard let image = exact?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                ?? cursor.image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)

        // FNV-1a over the pixels, and the bounds of those that are clearly visible (faint shadows do not count).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                for channel in 0..<4 { hash = (hash ^ UInt64(bytes[i + channel])) &* 0x100_0000_01b3 }
                if bytes[i + 3] > 25 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        // Not a single visible pixel.
        guard maxX >= minX else { return Pixels(hash: hash, visible: .zero) }
        let visible = CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                             width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        return Pixels(hash: hash, visible: visible)
    }
}
