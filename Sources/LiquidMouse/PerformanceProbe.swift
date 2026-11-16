import AppKit
import Darwin

/// Measures this process for developers (`--benchmark`): CPU, wakeups, memory and frames. Not a measure of energy.
enum PerformanceProbe {
    private static func usage() -> rusage_info_v0? {
        var value = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &value) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V0, $0)
            }
        }
        return result == 0 ? value : nil
    }

    static func run(seconds: Double) -> Bool {
        guard seconds.isFinite, seconds >= 3, seconds <= 60 else {
            print("Choose a sample duration between 3 and 60 seconds.")
            return false
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: appIdentifier)
            .allSatisfy({ $0 == .current }) else {
            print("Quit the other LiquidMouse instance before measuring: two engines would interfere.")
            return false
        }
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Accessibility: \(ElementProbe.isAllowed); CPU is percent of one core; wakeups are kernel counters.")
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return false }
        let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
        print("Mach CPU timebase: \(timebase.numer)/\(timebase.denom) ns per tick")
        let engine = Engine()
        guard engine.isSupported, !NSScreen.screens.isEmpty else { return false }
        defer { engine.isEnabled = false }
        engine.settings = SettingsStore.load()
        engine.settings.hidesWhenStill = .never
        let point = NSEvent.mouseLocation
        engine.pointerLocation = { point }
        engine.isButtonPressed = { false }
        print("form=\(engine.settings.body.form.rawValue), trail=\(engine.settings.body.trailLength), "
              + "response=\(engine.settings.body.trailResponse); real cursor hiding enabled")
        fflush(stdout)

        func wait(_ duration: Double) {
            let until = Date().addingTimeInterval(duration)
            while Date() < until {
                autoreleasepool { RunLoop.current.run(until: min(until, Date().addingTimeInterval(0.25))) }
            }
        }
        func sample(_ name: String) -> Bool {
            _ = engine.takeStats()
            guard let before = usage() else { return false }
            let start = CACurrentMediaTime()
            let realStart = NSEvent.mouseLocation
            var moved = false
            var appWasExcluded = engine.isPausedForApplication
            while CACurrentMediaTime() - start < seconds {
                wait(min(0.25, seconds - (CACurrentMediaTime() - start)))
                moved = moved || NSEvent.mouseLocation != realStart
                appWasExcluded = appWasExcluded || engine.isPausedForApplication
            }
            guard !appWasExcluded else {
                print("Invalid sample: a game or excluded app was in front, so LiquidMouse was suspended.")
                return false
            }
            let elapsed = CACurrentMediaTime() - start
            guard !moved else {
                print("Invalid sample: the real pointer moved during \(name). Keep it still and repeat the run.")
                fflush(stdout)
                return false
            }
            guard let after = usage() else { return false }
            let stats = engine.takeStats()
            let cpu = Double(after.ri_user_time - before.ri_user_time + after.ri_system_time - before.ri_system_time)
                * secondsPerTick / elapsed * 100
            print(String(format: "%@: %.1f s, CPU %.3f%%, interrupt wakeups %.1f/s, package wakeups %.1f/s, "
                         + "footprint %.1f MiB, %.1f fps, frame work %.3f ms",
                         name, elapsed, cpu, Double(after.ri_interrupt_wkups - before.ri_interrupt_wkups) / elapsed,
                         Double(after.ri_pkg_idle_wkups - before.ri_pkg_idle_wkups) / elapsed,
                         Double(after.ri_phys_footprint) / 1_048_576, stats.framesPerSecond, stats.averageWorkMs))
            fflush(stdout)
            return true
        }
        wait(1)
        guard sample("disabled") else { return false }
        engine.isEnabled = true
        wait(3)
        guard sample("idle, recent input") else { return false }
        // The hider's long-rest interval starts after 30 seconds without input.
        wait(31)
        guard sample("idle, long rest") else { return false }
        engine.isEnabled = false
        let start = CACurrentMediaTime()
        engine.pointerLocation = {
            let angle = (CACurrentMediaTime() - start) * 6
            return CGPoint(x: point.x + 70 * cos(angle), y: point.y + 70 * sin(angle))
        }
        engine.isEnabled = true
        wait(2)
        return sample("moving, simulated 420 pt/s")
    }
}
