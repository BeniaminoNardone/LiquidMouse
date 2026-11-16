import AppKit

let app = NSApplication.shared
let arguments = CommandLine.arguments

/// What follows a developer flag on the command line, when the flag is there.
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    return arguments.dropFirst(index + 1).first
}

// Developer tools. Each does its job and exits; they come before the check below, so they also work while the app
// runs. `--selftest [seconds]` measures the engine on this Mac's screens and fails if a check does.
if arguments.contains("--selftest") {
    exit(SelfTest.run(seconds: value(after: "--selftest").flatMap(Double.init) ?? 5) ? 0 : 1)
}
if arguments.contains("--benchmark") {
    exit(PerformanceProbe.run(seconds: value(after: "--benchmark").flatMap(Double.init) ?? 10) ? 0 : 1)
}
// `--gallery <file>`: every shape next to the macOS cursor it stands for. `--settings <file>`: the settings panel.
// `--icon <file>`: the app's icon, 1024 pixels square.
if let file = value(after: "--gallery") {
    Gallery.render(to: URL(fileURLWithPath: file))
    exit(0)
}
if let file = value(after: "--settings") {
    Gallery.renderSettings(to: URL(fileURLWithPath: file))
    exit(0)
}
if let file = value(after: "--icon") {
    Gallery.renderIcon(to: URL(fileURLWithPath: file))
    exit(0)
}
// `--film [it]`: the launch film's frames, raw, on standard output. `--film gif`: those of the README's animation.
// Scripts/make-film.sh makes the videos and the GIF from them.
if arguments.contains("--film") {
    switch value(after: "--film") {
    case "gif": Film.render(forGIF: true)
    case "it": Film.render(language: .italian)
    default: Film.render()
    }
    exit(0)
}

// One copy at a time: a second one would hide the cursor too and draw another on top. The copy already running
// shows its settings instead, as if its icon had been clicked. The bare binary (`swift run`) counts as the app too.
if NSRunningApplication.runningApplications(withBundleIdentifier: appIdentifier).contains(where: { $0 != .current }) {
    DistributedNotificationCenter.default().postNotificationName(AppDelegate.showSettingsNotification, object: nil,
                                                                 deliverImmediately: true)
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
// No Dock icon: the app lives in the menu bar.
app.setActivationPolicy(.accessory)
app.run()
