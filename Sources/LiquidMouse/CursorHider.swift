import AppKit
import Synchronization

/// Keeps the system cursor hidden, and notices mouse input while the engine sleeps, from a thread of its own.
///
/// Any app that asks the system to show the cursor shows it for everyone, ours included: Finder, Firefox and
/// Electron apps do it now and then. Checking once per display frame would let it flash for up to a frame, so this
/// thread checks every millisecond while the mouse is in use (every 4 when it is not), and hides the cursor again
/// the moment it reappears.
///
/// The same checks catch the mouse moving or a button going down while the engine sleeps. Event monitors were tried
/// first and missed some input, which left the cursor frozen.
///
/// It also guards against the worst failure there is: our cursor frozen while the real one is hidden. If the main
/// thread, which draws our cursor, stops answering, this thread gives the real cursor back and takes ours off the
/// screen until it answers again.
nonisolated final class CursorHider: Sendable {
    /// How often to check while the mouse is in use, while it is not, and once it has been left alone for
    /// `restingAfter` seconds: the pointer is not in use then, and saving the wake-ups matters more than a millisecond.
    private static let busyInterval: useconds_t = 1_000
    private static let quietInterval: useconds_t = 4_000
    private static let restingInterval: useconds_t = 10_000
    /// How long after the last input the checks stay fast, in seconds.
    private static let busyFor = 2.0
    private static let restingAfter = 30.0
    /// When the cursor is still visible this soon after hiding it, the system is holding it visible (the login
    /// window does) and asking again at once is pointless: it is asked again after `holdRetry`, then less and less
    /// often while the hold lasts. Every request adds to a count that has to be undone later, and asking every
    /// millisecond for hours (the login window holds the cursor) would pile up millions of them.
    private static let holdDetection = 0.005
    private static let holdRetry = 0.05
    private static let longestHoldRetry = 2.0

    /// Hide requests made, each needing a matching show request when we stop.
    private let requests = Atomic<Int>(0)
    /// How many times the cursor had to be hidden again since we started. For reports.
    private let reappearances = Atomic<Int>(0)
    private let running = Atomic<Bool>(false)
    private let hides = Atomic<Bool>(true)
    /// Set while the engine sleeps: the next mouse input calls `onInput` on the main thread.
    private let watchesInput = Atomic<Bool>(false)
    /// Whether typing counts as input too, for the cursor to hide while the user types.
    private let watchesKeys = Atomic<Bool>(false)
    private let onInput: @MainActor @Sendable () -> Void
    /// Until when, on the `CACurrentMediaTime` clock, to check at the fast rate.
    private let busyUntil = Atomic<UInt64>(0)
    private let stopped = DispatchSemaphore(value: 0)
    /// When the main thread last showed it is alive, on the `CACurrentMediaTime` clock.
    private let heartbeat = Atomic<UInt64>(0)
    /// How long the main thread may stay silent before we give the real cursor back, in seconds.
    private static let stallLimit = 0.4
    private let onStall: @Sendable (_ stalled: Bool) -> Void

    var reappearanceCount: Int { reappearances.load(ordering: .relaxed) }

    /// `onStall` is called on this thread, with true when the main thread stops answering and false when it
    /// comes back.
    init(onInput: @escaping @MainActor @Sendable () -> Void, onStall: @escaping @Sendable (Bool) -> Void) {
        self.onInput = onInput
        self.onStall = onStall
    }

    /// Call from the main thread, often: as long as these keep coming, the main thread is alive.
    func beat() {
        heartbeat.store(CACurrentMediaTime().bitPattern, ordering: .relaxed)
    }

    /// `hidesCursor` false only watches for input; tests use it to leave the user's cursor alone.
    func start(hidesCursor: Bool) {
        hides.store(hidesCursor, ordering: .relaxed)
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        beat()
        noteActivity()
        let thread = Thread { [self] in run() }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops watching and gives the cursor back.
    func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        stopped.wait()
        _ = WindowServer.setDockCursorOverride(false)
        watchesInput.store(false, ordering: .relaxed)
        for _ in 0..<requests.exchange(0, ordering: .relaxed) {
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }

    /// Call on mouse input: apps tend to show the cursor in response to it, so it is watched closely for a while.
    func noteActivity() {
        busyUntil.store((CACurrentMediaTime() + Self.busyFor).bitPattern, ordering: .relaxed)
    }

    /// Calls `onInput` once, on the main thread, at the next mouse movement or press, or when an app changes the
    /// cursor under a still pointer (a video player hiding it, say), which changes the shape to draw.
    func watchForInput(includingKeys: Bool) {
        watchesKeys.store(includingKeys, ordering: .relaxed)
        watchesInput.store(true, ordering: .releasing)
    }

    func stopWatchingForInput() {
        watchesInput.store(false, ordering: .releasing)
    }

    private func run() {
        var lastHide = -Double.infinity
        // Set while the system holds the cursor visible, with the wait before the next request.
        var holdWait: Double?
        if hides.load(ordering: .relaxed) {
            // Over the Dock the system hands the cursor to the Dock, which keeps it visible. Taking that override
            // for ourselves keeps it hidden there too (tried on macOS 27: the cursor stayed hidden over the Dock).
            if let error = WindowServer.setDockCursorOverride(true), error != 0 {
                logger.notice("The Dock's cursor override was refused (\(error)): the cursor may show over the Dock")
            }
            hide(&lastHide)
        }
        // Where the pointer was when the engine went to sleep, and the cursor it had.
        var restingAt: CGPoint?
        var restingSeed: Int32?
        var restingKeys = 0.0
        var stalled = false
        while running.load(ordering: .acquiring) {
            let now = CACurrentMediaTime()
            let silent = now - Double(bitPattern: heartbeat.load(ordering: .relaxed)) > Self.stallLimit
            if silent != stalled {
                stalled = silent
                // Ours off the screen first, then the real cursor back: hide requests are counted, so all of ours
                // are undone.
                onStall(stalled)
                if stalled {
                    for _ in 0..<requests.exchange(0, ordering: .relaxed) {
                        CGDisplayShowCursor(CGMainDisplayID())
                    }
                } else {
                    // Ours is drawn again by the next frame, which a resting engine would not have.
                    DispatchQueue.main.async(execute: onInput)
                }
            }
            if watchesInput.load(ordering: .acquiring), !stalled {
                let location = CGEvent(source: nil)?.location
                let pressed = [CGMouseButton.left, .right, .center].contains {
                    CGEventSource.buttonState(.combinedSessionState, button: $0)
                }
                // Seconds since the last key, as a time: it only goes up when a key is typed. The clock is read right
                // before the question, so that the same key always comes out at the same time.
                let typed = CACurrentMediaTime()
                    - CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                if restingAt == nil, let location, !pressed {
                    restingAt = location
                    restingSeed = WindowServer.cursorSeed
                    restingKeys = typed
                } else if location == nil || location != restingAt || pressed
                            || WindowServer.cursorSeed != restingSeed
                            || watchesKeys.load(ordering: .relaxed) && typed > restingKeys + 0.001 {
                    // An unreadable position wakes the engine too: better a needless frame than a frozen cursor.
                    restingAt = nil
                    watchesInput.store(false, ordering: .releasing)
                    noteActivity()
                    DispatchQueue.main.async(execute: onInput)
                }
            } else {
                restingAt = nil
            }
            if hides.load(ordering: .relaxed), !stalled, WindowServer.isCursorVisible == true {
                if let wait = holdWait {
                    if now - lastHide > wait {
                        hide(&lastHide)
                        holdWait = min(wait * 2, Self.longestHoldRetry)
                    }
                } else if now - lastHide < Self.holdDetection {
                    holdWait = Self.holdRetry
                    // The engine steps its cursor aside while the system's shows; asleep, it has to be woken for it.
                    if watchesInput.exchange(false, ordering: .acquiringAndReleasing) {
                        DispatchQueue.main.async(execute: onInput)
                    }
                } else {
                    reappearances.add(1, ordering: .relaxed)
                    hide(&lastHide)
                }
            } else {
                holdWait = nil
            }
            let busyUntil = Double(bitPattern: busyUntil.load(ordering: .relaxed))
            let interval = if now < busyUntil {
                Self.busyInterval
            } else if now < busyUntil - Self.busyFor + Self.restingAfter {
                Self.quietInterval
            } else {
                Self.restingInterval
            }
            usleep(interval)
        }
        stopped.signal()
    }

    private func hide(_ lastHide: inout Double) {
        CGDisplayHideCursor(CGMainDisplayID())
        requests.add(1, ordering: .relaxed)
        lastHide = CACurrentMediaTime()
    }
}
