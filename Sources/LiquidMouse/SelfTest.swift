import AppKit

/// Runs the engine on this Mac's screens, without a user, and prints what it measured: what the unit tests cannot
/// check, as it needs real displays. The simulated pointer circles around the real one and clicks now and then, so
/// every frame has something new to draw while the user's own cursor stays visible and where it is.
enum SelfTest {
    /// Returns whether every check passed.
    static func run(seconds: Double) -> Bool {
        guard seconds.isFinite, seconds >= 1, seconds <= 60 else {
            print("Choose a sample duration between 1 and 60 seconds.")
            return false
        }
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        for screen in NSScreen.screens {
            let size = "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
            print("screen \(size) pt, scale \(screen.backingScaleFactor), up to \(screen.maximumFramesPerSecond) Hz")
        }

        let engine = Engine()
        defer { engine.isEnabled = false }
        print("private cursor calls available: \(engine.isSupported)")
        guard engine.isSupported, !NSScreen.screens.isEmpty else { return false }

        let start = CACurrentMediaTime()
        engine.pointerLocation = {
            let angle = 2 * Double.pi * 1.5 * (CACurrentMediaTime() - start)
            let real = NSEvent.mouseLocation
            return CGPoint(x: real.x + 70 * cos(angle), y: real.y + 70 * sin(angle))
        }
        // Held for 0.1 s out of every 0.8.
        engine.isButtonPressed = { (CACurrentMediaTime() - start).truncatingRemainder(dividingBy: 0.8) < 0.1 }
        engine.hidesSystemCursor = false
        engine.settings.hidesWhenStill = .never
        engine.isEnabled = true
        _ = engine.takeStats()
        var drew = true
        for _ in 0..<Int(seconds) {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let stats = engine.takeStats()
            drew = drew && stats.framesPerSecond > 30
            print(String(format: "%.0f fps, work avg %.3f / worst %.3f ms, longest frame %.1f ms",
                         stats.framesPerSecond, stats.averageWorkMs, stats.worstWorkMs, stats.worstFrameMs))
        }
        print("draws at least 30 frames a second: \(drew ? "yes" : "NO")")

        // A display plugged in or woken rebuilds the displays: the windows must be reused, not piled up.
        func displaysChange(times: Int) -> Int {
            for _ in 0..<times {
                for _ in 0..<10 {
                    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification,
                                                    object: nil)
                }
                // As the app's own event loop does on every pass; this test runs outside of it.
                autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(0.4)) }
            }
            return NSApp.windows.count
        }
        let windows = displaysChange(times: 2)
        let later = displaysChange(times: 10)
        let reused = later <= windows
        print("windows reused when the displays change: \(reused ? "yes" : "NO") (\(windows), then \(later))")

        // A stuck main thread must not leave the user with a frozen cursor: the hider steps in (see the system log).
        print("blocking the main thread for 1.5 s")
        fflush(stdout)
        let overlays = NSApp.windows.compactMap { $0 as? OverlayWindow }.filter(\.isVisible)
        Thread.sleep(forTimeInterval: 1.5)
        let concealed = !overlays.isEmpty && overlays.allSatisfy { $0.contentView?.layer?.isHidden == true }
        print("stalled overlay hidden by the watchdog: \(concealed ? "yes" : "NO")")
        _ = engine.takeStats()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let recovered = engine.takeStats().framesPerSecond > 30
            && overlays.contains { $0.contentView?.layer?.isHidden == false }
        print("rendering recovers after the stall: \(recovered ? "yes" : "NO")")
        engine.isEnabled = false
        let stopped = overlays.allSatisfy { !$0.isVisible }
        print("overlays removed on disable: \(stopped ? "yes" : "NO")")
        return drew && reused && concealed && recovered && stopped
    }
}
