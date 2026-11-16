import AppKit
import Testing
@testable import LiquidMouse

@Suite struct CursorReaderTests {
    let reader: CursorReader

    init() {
        // Cursor images are drawn through the app's connection to the window server, which this makes.
        _ = NSApplication.shared
        reader = CursorReader(scale: 2)
    }

    @Test func readsTheStandardCursors() {
        #expect(reader.read(.arrow)?.context == .pointer)
        #expect(reader.read(.pointingHand)?.context == .link)
        #expect(reader.read(.openHand)?.context == .grab)
        #expect(reader.read(.closedHand)?.context == .grabbing)
        #expect(reader.read(.crosshair)?.context == .crosshair)
        #expect(reader.read(.operationNotAllowed)?.context == .notAllowed)
        #expect(reader.read(.dragCopy)?.context == .copy)
        #expect(reader.read(.dragLink)?.context == .alias)
        #expect(reader.read(.contextualMenu)?.context == .menu)
        #expect(reader.read(.zoomIn)?.context == .zoom(magnifies: true))
        #expect(reader.read(.zoomOut)?.context == .zoom(magnifies: false))
    }

    @Test func readsTheTextCursorWithItsHeight() throws {
        guard case .text(let halfHeight) = reader.read(.iBeam)?.context else {
            Issue.record("the I-beam was not read as text")
            return
        }
        #expect((7...16).contains(halfHeight))
    }

    @Test func readsWhichWaysAnEdgeCanBeDragged() {
        guard case .resize(let direction, let bothWays, let divider) = reader.read(.columnResize)?.context else {
            Issue.record("the column resize cursor was not read as a resize")
            return
        }
        #expect(abs(direction.dx) == 1 && direction.dy == 0)
        #expect(bothWays && divider)

        guard case .resize(let up, let upBothWays, _) = reader.read(.rowResize(directions: .up))?.context else {
            Issue.record("the row resize cursor was not read as a resize")
            return
        }
        #expect(up.dx == 0 && up.dy == 1)
        #expect(!upBothWays)
    }

    @Test func anInvisibleCursorMeansTheAppWantsItHidden() {
        let invisible = NSCursor(image: NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true },
                                 hotSpot: .zero)
        #expect(reader.read(invisible)?.context == .hidden)
    }

    @Test func anAppsOwnCursorIsNotReplaced() {
        let square = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            rect.insetBy(dx: 3, dy: 3).fill()
            return true
        }
        #expect(reader.read(NSCursor(image: square, hotSpot: .zero))?.context == .other)
    }

    @Test func identicalPixelsWithADifferentHotSpotRemainNative() {
        let arrow = NSCursor.arrow
        let custom = NSCursor(image: arrow.image,
                              hotSpot: CGPoint(x: arrow.hotSpot.x + 5, y: arrow.hotSpot.y + 5))
        #expect(reader.read(custom)?.context == .other)
    }

    @Test func invalidImageDimensionsFailSafely() {
        let oversized = NSImage(size: NSSize(width: 1e300, height: 20))
        #expect(reader.read(NSCursor(image: oversized, hotSpot: .zero)) == nil)
        let invalidScale = CursorReader(scale: .infinity)
        #expect(invalidScale.read(.arrow) == nil)
    }
}
