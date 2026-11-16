import AppKit
import simd

/// Replaces the system cursor with the liquid one: hides the real cursor, follows the pointer once per display
/// frame and draws the body in a window above everything.
final class Engine: NSObject {
    struct Settings: Equatable, Codable {
        var body = LiquidBody.Tuning()
        /// Hides the cursor while the user types, until the mouse moves, as macOS does with its own.
        var hidesWhileTyping = true
        /// When the cursor drains away after being left still. Some apps hide the system cursor in ways we cannot
        /// see, mostly full-screen videos and games: there it should go away too.
        var hidesWhenStill = StillHiding.inFullScreen
        /// Seconds without input before it does.
        var stillDelay = 3.0
        /// These apps keep their own cursor, even when they do not declare a game category.
        var excludedApplicationIDs: [String] = []
    }

    enum StillHiding: String, CaseIterable, Identifiable, Codable {
        case never
        case inFullScreen
        case always

        var id: Self { self }

        /// A choice this version does not know, saved by a later one, reads as the default rather than spoiling the
        /// settings.
        init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .inFullScreen
        }
    }

    /// Averages over the time since the previous `takeStats()` call.
    struct Stats: Equatable {
        var framesPerSecond = 0.0
        var averageWorkMs = 0.0
        var worstWorkMs = 0.0
        var worstFrameMs = 0.0
    }

    private struct Display {
        let screen: NSScreen
        let link: CADisplayLink
        let overlay: OverlayWindow
    }

    var settings = Settings() {
        didSet {
            guard settings != oldValue else { return }
            if settings.excludedApplicationIDs != oldValue.excludedApplicationIDs {
                applyRunState()
            } else {
                // A resting body has no frames to notice new appearance or hiding settings. Waking also
                // cancels the old idle deadline and refreshes which inputs the background watcher observes.
                wake()
            }
        }
    }
    var isEnabled = false {
        didSet { if isEnabled != oldValue { applyRunState() } }
    }
    /// Where the pointer is, in global screen coordinates, and whether a mouse button is down.
    /// Replaceable so tests can simulate input.
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    var isButtonPressed: () -> Bool = { NSEvent.pressedMouseButtons != 0 }
    var currentSystemCursor: () -> NSCursor? = { NSCursor.currentSystem }
    var systemCursorSeed: () -> Int32? = { WindowServer.cursorSeed }
    var frontApplicationIsGame: () -> Bool = { SystemState.frontAppIsGame() }
    var frontApplicationIdentifier: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    /// Tests run with this off: unattended, they must not leave the user without a cursor.
    var hidesSystemCursor = true
    /// False when this macOS no longer offers the private calls the engine needs.
    let isSupported: Bool

    private var displays: [Display] = []
    /// Windows left over from screens that went away, or from before the user left: kept for when they return.
    private var spareOverlays: [OverlayWindow] = []
    private var body = LiquidBody(at: .zero)
    private var reader = CursorReader(scale: 2)
    private var readerScale: CGFloat = 2
    private var context = CursorContext.pointer
    /// Unknown (or unreadable) cursors belong to the app that supplied them.
    private(set) var isPassingThrough = false
    private var reportedCursors: Set<String> = []
    private var systemCursorWasShown = false
    /// The cursor seed when `context` was read. A different value means an app has changed the cursor.
    private var readSeed: Int32?
    private var lastCursorRead: CFTimeInterval = 0
    private static let cursorReadInterval = 0.05
    private var lastTick: CFTimeInterval?
    private var lastLocation = CGPoint.zero
    private var lastInput: CFTimeInterval = 0
    /// When a key was last typed, on the same clock: after the last input, the cursor hides while typing. Shortcuts
    /// are seen too, but only typing counts.
    private var lastKeyPress: CFTimeInterval = 0
    private var lastKeySeen: CFTimeInterval = 0
    /// Whether the front app filled a screen, as asked once the pointer had been still for long enough: the answer
    /// holds until the next input.
    private var fullScreenAnswer: (input: CFTimeInterval, value: Bool)?
    /// What the system asks of the cursor, read once a second: its appearance, its size, whether the screen is
    /// being recorded.
    private var systemIsDark = false
    private var pointerScale = 1.0
    private var screenIsRecorded = false
    /// The accessibility setting: no splash and no bounce while it is on.
    private var reducesMotion = false
    private let curtain = Curtain()
    private lazy var hider = CursorHider(onInput: { [weak self] in self?.wake() }, onStall: { [curtain] stalled in
        if stalled {
            curtain.drop()
            logger.error("The main thread stopped answering: real cursor given back, ours taken away")
        } else {
            logger.notice("The main thread is answering again")
        }
    })
    /// Tells the hider the main thread is alive, and restarts the frame loop if it stops when it should not.
    private var heartbeat: Timer?
    /// True while the system is in front: the screen locked or asleep, the screensaver on, another user's session, or
    /// one of the system's own prompts. The engine then lets go of everything (no windows, no frame loop, the system
    /// cursor given back) until it is gone.
    private var isAway = false
    /// Games keep their own cursor, including in menus. This is temporary; it never changes the enabled setting.
    private(set) var isGameInFront = false
    private(set) var isPausedForApplication = false
    private var lastAwayCheck: CFTimeInterval = 0
    /// What the screensaver's notifications last said.
    private var screensaverStarted = false
    /// Plugging in or waking a display sends a burst of change notifications: the windows are rebuilt once, after it.
    private var pendingRebuild: Timer?
    /// Restarts of the frame loop since it last drew a frame. Each one waits twice as long as the one before, so a
    /// display that cannot draw is not flooded with new windows: once, with the screen locked, that ran thousands of
    /// times and hung WindowServer.
    private var failedRestarts = 0
    /// Every restart of the frame loop since the engine was made, for the tests.
    private(set) var frameLoopRestarts = 0
    private var lastRestart: CFTimeInterval = 0
    private var lastPulse: CFTimeInterval = 0
    /// Set when a restart did not bring the frames back: the real cursor is given back until they come.
    private var handsCursorBack = false
    /// Keeps macOS from slowing our timers down as it does for apps in the background ("App Nap"): a delayed
    /// heartbeat looks like a stall, and a cursor cannot afford to lag. It must not keep the Mac awake, though:
    /// plain `.userInitiated` also stops it from going to sleep on its own.
    private var activity: NSObjectProtocol?
    private var lastFrame: CFTimeInterval = 0
    /// Set when the frame loop starts or resumes: a frame is due at once, since the body has something to draw, and
    /// by this time at the latest. A display link made while the screens wake can stay silent; it is replaced then.
    private var frameDue: CFTimeInterval?
    /// Whether the cursor was being drawn when `applyRunState` last ran.
    private var isRunning = false
    /// While the cursor rests the display links are paused, to cost nothing; mouse input brings them back.
    private var isAsleep = false
    /// Since when the body has not changed; the engine pauses once that has lasted `restBeforeSleep`.
    private var settledSince: CFTimeInterval?
    private static let restBeforeSleep = 0.5
    /// How long a frame loop that has just started or resumed may take to draw its first frame: a few frames.
    private static let frameGrace = 0.12
    /// Wakes the engine when the cursor's idle time is up, to let it drain away.
    private var idleWake: Timer?
    /// The hider's count when last reported.
    private var reportedReappearances = 0

    /// Whether macOS lets us ask other apps what is under the pointer. Rechecked now and then, as the user can
    /// switch it on at any time.
    private var canSeeButtons = ElementProbe.isAllowed
    private var lastPermissionCheck: CFTimeInterval = 0
    private let probe = ElementProbe()
    /// True while the Accessibility API says the pointer is over a button or a link.
    private var buttonProbe = ButtonProbeState()

    private var statsStart = CACurrentMediaTime()
    private var frames = 0
    private var workTotal = 0.0
    private var workWorst = 0.0
    private var frameWorst = 0.0

    override init() {
        isSupported = WindowServer.allowBackgroundCursorControl()
        super.init()
        isAway = SystemState.isInFront(screensaverStarted: false)
        isGameInFront = frontApplicationIsGame()
        rebuildDisplays()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(checkAway), name: name, object: nil)
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(self, selector: #selector(frontChanged), name: name, object: nil)
        }
        // Delivered at once: macOS holds distributed notifications back from apps that are not active, and this one
        // almost never is.
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributed.addObserver(self, selector: #selector(checkAway), name: Notification.Name(name), object: nil,
                                    suspensionBehavior: .deliverImmediately)
        }
        for name in ["com.apple.screensaver.didstart", "com.apple.screensaver.didstop"] {
            distributed.addObserver(self, selector: #selector(screensaverChanged(_:)), name: Notification.Name(name),
                                    object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    func takeStats() -> Stats {
        let now = CACurrentMediaTime()
        let stats = Stats(framesPerSecond: Double(frames) / max(now - statsStart, 1e-3),
                          averageWorkMs: frames > 0 ? workTotal / Double(frames) * 1000 : 0,
                          worstWorkMs: workWorst * 1000,
                          worstFrameMs: frameWorst * 1000)
        statsStart = now
        frames = 0
        workTotal = 0
        workWorst = 0
        frameWorst = 0
        return stats
    }

    // MARK: - Displays

    @objc private func screensChanged() {
        pendingRebuild?.invalidate()
        pendingRebuild = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildDisplays() }
        }
    }

    private func rebuildDisplays() {
        buttonProbe.invalidate()
        pendingRebuild?.invalidate()
        pendingRebuild = nil
        displays.forEach { $0.link.invalidate() }
        var overlays = displays.map(\.overlay) + spareOverlays
        // Away, there is nothing to draw on.
        displays = (isAway ? [] : NSScreen.screens).map { screen in
            let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
            let fastest = Float(screen.maximumFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, fastest), maximum: fastest,
                                                            preferred: fastest)
            link.add(to: .main, forMode: .common)
            let overlay = overlays.isEmpty ? OverlayWindow(screen: screen) : overlays.removeFirst()
            overlay.place(on: screen)
            return Display(screen: screen, link: link, overlay: overlay)
        }
        for overlay in overlays {
            overlay.clear()
            overlay.orderOut(nil)
        }
        spareOverlays = overlays
        applyCapture()
        curtain.cover(displays.compactMap { $0.overlay.contentView?.layer })
        // Making the reader draws and hashes every standard cursor: only when the sharpest screen changes.
        let scale = displays.map(\.screen.backingScaleFactor).max() ?? readerScale
        if scale != readerScale {
            reader = CursorReader(scale: scale)
            readerScale = scale
        }
        readSeed = nil
        applyRunState()
    }

    private func display(containing point: CGPoint) -> Display? {
        // Screen frames exclude their top and right edges, where the pointer can still sit: those count only when
        // no screen contains the point, or the cursor would be drawn on the neighbor across the border.
        displays.first { $0.screen.frame.contains(point) }
            ?? displays.first { $0.screen.frame.insetBy(dx: -1, dy: -1).contains(point) } ?? displays.first
    }

    /// Starts or stops everything to match whether the cursor should be drawn: on, supported, and the system not in
    /// front. Also run after every rebuild of the displays, which replaces the frame loop.
    private func applyRunState() {
        isGameInFront = frontApplicationIsGame()
        isPausedForApplication = isGameInFront || frontApplicationIsExcluded()
        let running = isEnabled && isSupported && !isAway && !isPausedForApplication
        let starting = running && !isRunning
        for display in displays {
            display.link.isPaused = !running
            if running {
                display.overlay.orderFrontRegardless()
            } else {
                display.overlay.clear()
                display.overlay.orderOut(nil)
            }
        }
        // Remove our image before releasing our cursor hide requests back to the foreground app.
        if !running { CATransaction.flush() }
        lastTick = nil
        isAsleep = false
        settledSince = nil
        idleWake?.invalidate()
        hider.stopWatchingForInput()
        // A fresh body, so the cursor pops in when turned on, or back, in the system's current colors and size.
        // A restart of the frame loop keeps everything as it is, a cursor hidden for typing included.
        if starting {
            body = LiquidBody(at: .zero)
            readSeed = nil
            buttonProbe.invalidate()
            lastInput = CACurrentMediaTime()
            readSystemSettings()
        }
        isRunning = running
        lastFrame = CACurrentMediaTime()
        frameDue = running ? lastFrame + Self.frameGrace : nil
        heartbeat?.invalidate()
        heartbeat = nil
        if isEnabled, isSupported {
            // While away it only looks, once a second, for the user to come back.
            let timer = Timer(timeInterval: isAway || isPausedForApplication ? 1 : 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkPulse() }
            }
            // Common modes, so it keeps beating while a menu or a drag holds the run loop.
            RunLoop.main.add(timer, forMode: .common)
            heartbeat = timer
        }
        if running {
            if handsCursorBack {
                hider.stop()
            } else {
                hider.start(hidesCursor: hidesSystemCursor && !isPassingThrough)
            }
            activity = activity ?? ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Drawing the cursor")
        } else {
            buttonProbe.invalidate()
            hider.stop()
            activity.map(ProcessInfo.processInfo.endActivity)
            activity = nil
        }
    }

    private func checkPulse() {
        let now = CACurrentMediaTime()
        // The notifications should say when the user leaves and comes back; this catches any that go missing.
        if isAway || now - lastAwayCheck > 1 {
            lastAwayCheck = now
            checkAway()
            if !isAway {
                readSystemSettings()
            }
        }
        if foregroundPolicyChanged() {
            applyRunState()
        }
        guard isRunning else { return }
        hider.beat()
        // Content may change beneath a stationary pointer without changing the system cursor image.
        // This uses the existing heartbeat; unchanged answers do not wake the display links.
        lookUnderPointer(at: pointerLocation(), now: now)
        if isAsleep {
            // The watcher may miss an input arriving just as it takes its resting snapshot. Compare with
            // the position actually drawn, so a single missed input cannot leave the cursor frozen.
            let previousKey = lastKeyPress
            noteTyping()
            let cursorChanged = readCursor(now: now)
            if pointerLocation() != lastLocation || isButtonPressed() || lastKeyPress != previousKey || cursorChanged {
                wake()
            }
        }
        // After the main thread was stuck no frame could come either: the frame loop gets its chance first.
        if now - lastPulse > 0.5 {
            lastFrame = max(lastFrame, now)
            frameDue = frameDue.map { _ in now + Self.frameGrace }
        }
        lastPulse = now
        // No frames while the engine rests is normal. It only matters if the pointer moves and nothing follows it.
        let wait = min(2 * pow(2, Double(failedRestarts)), 60)
        let missedDue = frameDue.map { now > $0 } ?? false
        let stopped = now - lastFrame > 0.25 && pointerLocation() != lastLocation
        if !isAsleep, missedDue || stopped, now - lastRestart > wait {
            failedRestarts += 1
            frameLoopRestarts += 1
            lastRestart = now
            let silence = Int((now - lastFrame) * 1000)
            let reason = missedDue ? "no first frame after starting" : "no frame while the pointer moves"
            report("frame loop restarted, \(reason), \(silence) ms without frames (try \(failedRestarts))")
            if failedRestarts > 1, !handsCursorBack {
                handsCursorBack = true
                report("the restart did not help: real cursor given back until the frames come back")
            }
            rebuildDisplays()
        }
    }

    private func readSystemSettings() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scale = WindowServer.pointerScale ?? 1
        let recorded = WindowServer.isScreenRecorded ?? true
        if recorded != screenIsRecorded {
            screenIsRecorded = recorded
            applyCapture()
        }
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard dark != systemIsDark || scale != pointerScale || calm != reducesMotion else { return }
        systemIsDark = dark
        pointerScale = scale
        reducesMotion = calm
        // The cursor looks different now: if the engine was resting, it has to draw again.
        wake()
    }

    private func applyCapture() {
        for overlay in displays.map(\.overlay) + spareOverlays {
            overlay.setCapturable(screenIsRecorded)
        }
    }

    /// Another app in front, or another Space: it may be full screen, or no longer, without the mouse moving.
    @objc private func frontChanged() {
        fullScreenAnswer = nil
        buttonProbe.invalidate()
        readSeed = nil
        checkAway()
        if foregroundPolicyChanged() {
            applyRunState()
            report(isPausedForApplication ? "foreground app uses its original cursor" : "liquid cursor resumed")
        }
        wake()
    }

    private func frontApplicationIsExcluded() -> Bool {
        guard !settings.excludedApplicationIDs.isEmpty, let id = frontApplicationIdentifier() else { return false }
        return settings.excludedApplicationIDs.contains(id)
    }

    private func foregroundPolicyChanged() -> Bool {
        let game = frontApplicationIsGame()
        return game != isGameInFront || (game || frontApplicationIsExcluded()) != isPausedForApplication
    }

    @objc private func screensaverChanged(_ notification: Notification) {
        screensaverStarted = notification.name.rawValue.hasSuffix("didstart")
        checkAway()
    }

    @objc private func checkAway() {
        let away = SystemState.isInFront(screensaverStarted: screensaverStarted)
        guard away != isAway else { return }
        isAway = away
        report(away ? "the system is in front: cursor given back" : "the system is gone: cursor taken over again")
        // Screens may have come and gone in the meantime.
        rebuildDisplays()
    }

    private func sleep(now: CFTimeInterval) {
        isAsleep = true
        displays.forEach { $0.link.isPaused = true }
        hider.watchForInput(includingKeys: settings.hidesWhileTyping)
        // Woken when the stillness is up, to drain away if it should.
        let stillUntil = lastInput + settings.stillDelay + 0.01
        if settings.hidesWhenStill != .never, stillUntil > now {
            let timer = Timer(timeInterval: stillUntil - now, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            }
            // Common modes, so the cursor still drains away while a menu is open.
            RunLoop.main.add(timer, forMode: .common)
            idleWake = timer
        }
    }

    private func wake() {
        guard isAsleep else { return }
        isAsleep = false
        settledSince = nil
        idleWake?.invalidate()
        idleWake = nil
        hider.stopWatchingForInput()
        // As if the last frame had just been drawn, so the first one after waking already moves.
        let now = CACurrentMediaTime()
        lastTick = now - 1.0 / 60
        // The time spent resting is not time without frames: counted as such, the heartbeat that wakes the engine
        // would restart the frame loop at once. A frame loop that really stays silent misses `frameDue` instead.
        lastFrame = now
        frameDue = now + Self.frameGrace
        displays.forEach { $0.link.isPaused = false }
    }

    // MARK: - Frame loop

    @objc private func tick(_ link: CADisplayLink) {
        guard isRunning, !isAsleep else { return }
        let start = CACurrentMediaTime()
        let location = pointerLocation()
        guard let display = display(containing: location) else { return }
        guard display.link === link else {
            displays.first { $0.link === link }?.overlay.clear()
            return
        }
        // Only the screen under the pointer counts: the frame loop that matters is the one drawing the cursor.
        lastFrame = start
        frameDue = nil
        failedRestarts = 0
        if handsCursorBack {
            handsCursorBack = false
            hider.start(hidesCursor: hidesSystemCursor && !isPassingThrough)
        }
        // Back after the hider took our cursor away during a stall.
        display.overlay.contentView?.layer?.isHidden = false

        // A zero step on the first frame makes the body start at rest under the pointer.
        let dt = lastTick.map { start - $0 } ?? 0
        lastTick = start
        let pressed = isButtonPressed()
        if location != lastLocation || pressed {
            lastInput = start
            hider.noteActivity()
        }
        lastLocation = location

        _ = readCursor(now: start)
        updateCursorOwnership()

        lookUnderPointer(at: location, now: start)
        // Most apps keep the standard arrow over their buttons; there the Accessibility API tells us better.
        let shapeContext = context == .pointer && canSeeButtons && buttonProbe.overClickable ? .link : context

        noteTyping()
        let hidden = shouldHide(now: start)
        var tuning = settings.body
        tuning.dotRadius *= pointerScale
        if reducesMotion {
            tuning.splashes = false
            tuning.bounce = 0
        }
        body.tuning = tuning
        body.step(to: SIMD2(Double(location.x), Double(location.y)), dt: dt, context: shapeContext,
                  pressed: pressed, present: !hidden)

        let reappearances = hider.reappearanceCount
        if reappearances > reportedReappearances {
            report("system cursor shown again, hidden at once (\(reappearances) so far)", often: true)
            reportedReappearances = reappearances
        }
        // The hider puts the system cursor away within a millisecond. If it is still visible, the system is holding
        // it, and ours steps aside rather than make two.
        let shape = body.shape
        let systemCursorShown = !isPassingThrough && hidesSystemCursor && WindowServer.isCursorVisible == true
        if systemCursorShown != systemCursorWasShown {
            systemCursorWasShown = systemCursorShown
            let state = systemCursorShown ? "held visible by the system" : "hidden again"
            report("system cursor \(state) at \(Int(location.x)),\(Int(location.y))")
        }
        let changed = if !isPassingThrough, !systemCursorShown, !shape.isEmpty {
            display.overlay.drawBody(shape, at: location, reach: tuning.reach,
                                     look: tuning.appearance.resolved(systemIsDark: systemIsDark))
        } else {
            display.overlay.clear()
        }
        if changed {
            // Send the change to the compositor now instead of at the end of this run loop pass.
            CATransaction.flush()
        }
        // Nothing moves until the mouse does: stop the frame loop rather than redraw the same thing. Only after a
        // short while, though: a slowly moving pointer settles between two steps, and pausing and restarting every
        // few frames makes it stutter.
        if body.isSettled, !pressed, !systemCursorShown {
            settledSince = settledSince ?? start
            if start - (settledSince ?? start) > Self.restBeforeSleep {
                sleep(now: start)
            }
        } else {
            settledSince = nil
        }

        let work = CACurrentMediaTime() - start
        frames += 1
        workTotal += work
        workWorst = max(workWorst, work)
        frameWorst = max(frameWorst, dt)
    }

    /// Notes a key typed since the last frame. Shortcuts do not count: macOS keeps its cursor for those.
    private func noteTyping() {
        guard settings.hidesWhileTyping else { return }
        // The clock is read right before the question, so that the same key always comes out at the same time.
        let typed = CACurrentMediaTime()
            - CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        guard typed > lastKeySeen + 0.001 else { return }
        // Judged once, with the modifiers held when it is first seen: released later, they do not make it typing.
        lastKeySeen = typed
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if !flags.contains(.maskCommand), !flags.contains(.maskControl) {
            lastKeyPress = typed
        }
    }

    /// Whether the cursor should be out of sight, where the system's would be, or where the settings ask.
    private func shouldHide(now: CFTimeInterval) -> Bool {
        // An app that makes the cursor invisible (a video, a game, a page with no cursor) wants ours gone too.
        if context == .hidden { return true }
        if settings.hidesWhileTyping, lastKeyPress > lastInput { return true }
        guard now - lastInput > settings.stillDelay else { return false }
        switch settings.hidesWhenStill {
        case .never: return false
        case .always: return true
        case .inFullScreen:
            if let answer = fullScreenAnswer, answer.input == lastInput { return answer.value }
            let value = SystemState.frontAppFillsAScreen()
            fullScreenAnswer = (lastInput, value)
            return value
        }
    }

    /// Returns whether the meaning changed; also called while resting, including without the private seed API.
    @discardableResult
    private func readCursor(now: CFTimeInterval) -> Bool {
        let seed = systemCursorSeed() ?? Int32(truncatingIfNeeded: Int(now * 10))
        guard seed != readSeed, now - lastCursorRead > Self.cursorReadInterval else { return false }
        readSeed = seed
        lastCursorRead = now
        let reading = currentSystemCursor().flatMap { reader.read($0) }
        if let reading, reading.context == .other, reportedCursors.insert(reading.kind).inserted {
            report("unrecognized cursor \(reading.description)", often: true)
        }
        let next = reading?.context ?? .other
        // A failed read is retried even if the image seed stays unchanged.
        if reading == nil { readSeed = nil }
        guard next != context else { return false }
        context = next
        buttonProbe.invalidate()
        return true
    }

    private func updateCursorOwnership() {
        let passThrough = context == .other
        guard passThrough != isPassingThrough else { return }
        // Remove every overlay before giving back the real cursor, including the screen just left.
        displays.forEach { $0.overlay.clear() }
        CATransaction.flush()
        hider.stop()
        isPassingThrough = passThrough
        // Keep the input/seed watcher alive in pass-through mode, so a stationary cursor can change back too.
        hider.start(hidesCursor: hidesSystemCursor && !passThrough)
        report(passThrough ? "app-specific cursor given back" : "recognized cursor: liquid cursor resumed", often: true)
    }

    /// What a hit test at `location` would be about, or nil where buttons are not looked for. Read again when the
    /// answer arrives, to throw away an answer about a place the pointer has left.
    private func buttonTarget(at location: CGPoint) -> ButtonProbeState.Target? {
        guard isRunning, canSeeButtons, context == .pointer, !NSApp.isActive,
              !SystemState.isInMenuBar(location),
              !NSApp.windows.contains(where: {
                  $0.isVisible && !($0 is OverlayWindow) && $0.frame.contains(location)
              }) else { return nil }
        return .init(location: location, application: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    /// Asks while moving, and periodically while still to catch scrolling and changing content.
    private func lookUnderPointer(at location: CGPoint, now: CFTimeInterval) {
        if now - lastPermissionCheck > 2 {
            lastPermissionCheck = now
            canSeeButtons = ElementProbe.isAllowed
        }
        let previous = buttonProbe.overClickable
        buttonProbe.observe(buttonTarget(at: location))
        if previous != buttonProbe.overClickable { wake() }
        guard let request = buttonProbe.request(now: now) else { return }
        // The Accessibility API measures from the top-left corner of the main screen, AppKit from the bottom-left.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        // Noted only once really asked: with an answer still out the question is skipped, and must be asked again
        // on a later frame, or the shape would follow an earlier position after the pointer stops.
        let asked = probe.lookUp(at: CGPoint(x: location.x, y: mainHeight - location.y)) { [weak self] finding in
            guard let self else { return }
            let previous = self.buttonProbe.overClickable
            self.canSeeButtons = ElementProbe.isAllowed
            self.buttonProbe.observe(self.buttonTarget(at: self.pointerLocation()))
            let accepted = self.buttonProbe.accept(finding.clickable, for: request)
            if previous != self.buttonProbe.overClickable { self.wake() }
            if accepted, finding.clickable == true, !previous, let role = finding.role {
                self.report("over a \(role)", often: true)
            }
        }
        if asked {
            buttonProbe.didRequest(request, now: now)
        }
    }

    /// Notes what happened, and in which app, in the system log (see `logger`). Events that come `often` are kept
    /// out of the log on disk.
    private func report(_ event: String, often: Bool = false) {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        if often {
            logger.info("\(event, privacy: .public), in \(app, privacy: .public)")
        } else {
            logger.notice("\(event, privacy: .public), in \(app, privacy: .public)")
        }
    }
}
