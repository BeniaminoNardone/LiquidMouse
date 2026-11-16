import AppKit

/// What the engine asks macOS about the session around it. These are the guesses most likely to need updating after
/// a macOS release: bundle identifiers of system apps, and keys Apple does not document.
enum SystemState {
    // Read the bundle only when the foreground process changes, not on every heartbeat.
    private static var gameCheck: (pid: pid_t, launched: Date?, value: Bool)?

    /// Games own their cursor throughout menus and gameplay. In particular, a game's hide/lock requests cannot
    /// be distinguished from our own hide requests by asking for the global cursor visibility.
    static func frontAppIsGame() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            gameCheck = nil
            return false
        }
        if let check = gameCheck, check.pid == app.processIdentifier, check.launched == app.launchDate {
            return check.value
        }
        let category = app.bundleURL.flatMap { Bundle(url: $0) }?
            .object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        let value = isGame(category: category)
        gameCheck = (app.processIdentifier, app.launchDate, value)
        return value
    }

    static func isGame(category: String?) -> Bool {
        guard let category else { return false }
        return category == "public.app-category.games"
            || category.hasPrefix("public.app-category.") && category.hasSuffix("-games")
    }

    /// System apps whose only window is a prompt to answer: a permission, a password, a downloaded app's first
    /// launch. They are drawn above every window, ours included, so while one is in front the real cursor takes over.
    private static let prompts: Set<String> = [
        "com.apple.UserNotificationCenter", "com.apple.tcc.AuthorizationPromptService", "com.apple.SecurityAgent",
        "com.apple.coreservices.uiagent", "com.apple.accessibility.universalAccessAuthWarn", "com.apple.NetAuthAgent",
        "com.apple.EscrowSecurityAlert", "com.apple.security.Keychain-Circle-Notification",
    ]
    static let screensaverID = "com.apple.ScreenSaver.Engine"

    /// Whether the system is in front: one of its prompts or the screensaver, the screens asleep or locked, or
    /// another user's session. `screensaverStarted` is what its notifications said, which the process confirms.
    static func isInFront(screensaverStarted: Bool) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let front, prompts.contains(front) || front == screensaverID { return true }
        if screensaverStarted, !NSRunningApplication.runningApplications(withBundleIdentifier: screensaverID).isEmpty {
            return true
        }
        if displaysAreAsleep() { return true }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        let onConsole = session[kCGSessionOnConsoleKey] as? Bool ?? true
        let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        return !onConsole || locked
    }

    private static func displaysAreAsleep() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }

    /// Whether the front app has a window covering a whole screen: full screen, as videos and games usually are.
    static func frontAppFillsAScreen() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // Window bounds are measured from the top-left corner of the main screen, AppKit's from the bottom-left.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: mainHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
        }
        return windows.contains { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid, window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return false }
            return screens.contains(frame)
        }
    }

    /// Whether `point` is in the menu bar of its screen, where this app's own icon is, on every screen.
    static func isInMenuBar(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { screen in
            let height = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
            return screen.frame.contains(point) && point.y >= screen.frame.maxY - height
        }
    }
}
