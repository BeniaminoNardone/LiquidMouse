import AppKit
import Testing
@testable import LiquidMouse

/// Uses real display links, windows and the hider's input watcher. Never hides the user's own cursor.
@Suite(.serialized) struct EngineIntegrationTests {
    @Test func restingCursorUpdatesWhenPreferencesChange() {
        _ = NSApplication.shared
        let engine = Engine()
        defer { engine.isEnabled = false }
        engine.hidesSystemCursor = false
        engine.frontApplicationIsGame = { false }
        engine.currentSystemCursor = { .arrow }
        engine.systemCursorSeed = { 1 }
        let point = NSEvent.mouseLocation
        engine.pointerLocation = { point }
        engine.isButtonPressed = { false }
        engine.settings.hidesWhenStill = .never
        engine.isEnabled = true
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        _ = engine.takeStats()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        #expect(engine.takeStats().framesPerSecond == 0)

        engine.settings.body.form = .dot
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        #expect(engine.takeStats().framesPerSecond > 0)
    }

    @Test func heartbeatRecoversInputMissedByTheBackgroundWatcher() {
        _ = NSApplication.shared
        let engine = Engine()
        defer { engine.isEnabled = false }
        engine.hidesSystemCursor = false
        engine.frontApplicationIsGame = { false }
        engine.currentSystemCursor = { .arrow }
        engine.systemCursorSeed = { 1 }
        var point = NSEvent.mouseLocation
        engine.pointerLocation = { point }
        engine.isButtonPressed = { false }
        engine.settings.hidesWhenStill = .never
        engine.isEnabled = true
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        _ = engine.takeStats()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        #expect(engine.takeStats().framesPerSecond == 0)

        // Simulates an input the watcher missed: only the position the engine reads changes.
        point.x += 30
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        #expect(engine.takeStats().framesPerSecond > 0)
        // Waking is enough: the time it rested is not a stalled frame loop, and must not restart it.
        #expect(engine.frameLoopRestarts == 0)
    }

    @Test func exclusionsApplyImmediatelyAndDoNotOverrideManualDisable() {
        _ = NSApplication.shared
        let engine = Engine()
        defer { engine.isEnabled = false }
        engine.hidesSystemCursor = false
        engine.frontApplicationIsGame = { false }
        engine.frontApplicationIdentifier = { "com.example.editor" }
        engine.isEnabled = true
        #expect(!engine.isPausedForApplication)
        engine.settings.excludedApplicationIDs = ["com.example.editor"]
        #expect(engine.isPausedForApplication)
        #expect(engine.isEnabled)
        engine.isEnabled = false
        engine.settings.excludedApplicationIDs = []
        #expect(!engine.isPausedForApplication)
        #expect(!engine.isEnabled)
        #expect(!NSApp.windows.contains { $0 is OverlayWindow && $0.isVisible })
    }

    @Test func unknownCursorsPassThroughAndKnownCursorsResumeWhileStationary() throws {
        _ = NSApplication.shared
        #expect(!NSScreen.screens.isEmpty)
        let engine = Engine()
        defer { engine.isEnabled = false }
        engine.frontApplicationIsGame = { false }
        #expect(engine.isSupported)
        engine.hidesSystemCursor = false
        engine.settings.hidesWhenStill = .never
        let location = NSEvent.mouseLocation
        engine.pointerLocation = { location }
        engine.isButtonPressed = { false }
        let square = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.black.setFill()
            rect.insetBy(dx: 2, dy: 2).fill()
            return true
        }
        var cursor: NSCursor? = NSCursor(image: square, hotSpot: .zero)
        var seed: Int32 = 1
        engine.currentSystemCursor = { cursor }
        engine.systemCursorSeed = { seed }
        engine.isEnabled = true

        func run(_ seconds: Double) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }
        run(1.5) // Enough for the pass-through body to settle and the display links to sleep.
        #expect(engine.isPassingThrough)
        _ = engine.takeStats()
        run(0.3)
        #expect(engine.takeStats().framesPerSecond == 0)

        cursor = .arrow
        seed += 1
        run(0.3)
        #expect(!engine.isPassingThrough)

        // Unreadable images must not be replaced with a misleading liquid arrow either.
        cursor = nil
        seed += 1
        run(0.3)
        #expect(engine.isPassingThrough)
        cursor = .iBeam
        // A failed read is retried even without a new seed.
        run(0.3)
        #expect(!engine.isPassingThrough)

        // The periodic fallback must work while sleeping if the private seed API is unavailable.
        engine.systemCursorSeed = { nil }
        run(1.5)
        cursor = NSCursor(image: square, hotSpot: .zero)
        run(0.3)
        #expect(engine.isPassingThrough)
        engine.isEnabled = false
        engine.isEnabled = true
        cursor = .arrow
        run(0.3)
        #expect(!engine.isPassingThrough)
    }

    @Test func gamesSuspendEverythingAndLeavingRespectsTheEnabledSetting() {
        _ = NSApplication.shared
        var game = true
        let engine = Engine()
        defer { engine.isEnabled = false }
        engine.hidesSystemCursor = false
        engine.settings.hidesWhenStill = .never
        engine.settings.hidesWhileTyping = false
        engine.frontApplicationIsGame = { game }
        engine.currentSystemCursor = { .arrow }
        engine.systemCursorSeed = { 1 }
        let location = NSEvent.mouseLocation
        engine.pointerLocation = { location }
        engine.isButtonPressed = { false }

        func run(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func changeFront(toGame value: Bool) {
            game = value
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
                                                       object: nil)
            run(0.2)
        }
        func overlaysAreVisible() -> Bool {
            NSApp.windows.contains { $0 is OverlayWindow && $0.isVisible }
        }

        // Starting inside a game must not briefly start drawing or change the saved enabled state.
        engine.isEnabled = true
        run(0.2)
        #expect(engine.isGameInFront)
        #expect(engine.isEnabled)
        #expect(!overlaysAreVisible())
        #expect(engine.takeStats().framesPerSecond == 0)

        changeFront(toGame: false)
        #expect(!engine.isGameInFront)
        #expect(overlaysAreVisible())
        #expect(engine.takeStats().framesPerSecond > 0)
        changeFront(toGame: true)
        #expect(!overlaysAreVisible())
        _ = engine.takeStats()
        run(1.2) // Includes the recovery heartbeat: it must not restart drawing while a game is active.
        #expect(engine.takeStats().framesPerSecond == 0)

        // Polling recovers if an application activation notification was missed.
        game = false
        run(1.2)
        #expect(!engine.isGameInFront)
        #expect(overlaysAreVisible())
        changeFront(toGame: true)
        engine.isEnabled = false
        changeFront(toGame: false)
        #expect(!engine.isEnabled)
        #expect(!overlaysAreVisible())
        engine.isEnabled = true
        run(0.2)
        #expect(overlaysAreVisible())
    }
}
