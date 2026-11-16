import AppKit
import SwiftUI

/// Puts LiquidMouse in the menu bar: an icon that opens the settings.
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    /// Sent by a second copy of the app, started while this one runs.
    static let showSettingsNotification = Notification.Name(appIdentifier + ".showSettings")
    private let engine = Engine()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    /// Watches for clicks outside the app while the settings are shown.
    private var outsideClicks: Any?
    /// Watches for the Escape key while the settings are shown.
    private var escapeKey: Any?
    private var signalSources: [DispatchSourceSignal] = []
    /// Made at launch, which starts the engine with the saved settings.
    private lazy var model = SettingsModel(engine: engine)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let firstLaunch = !SettingsStore.hasSavedSettings
        popover.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        // Closed by this class alone, and shown and hidden at once: while a popover fades it ignores clicks, half a
        // second each way, so a second click on the icon was lost.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        // At the press, as the system's own menu bar items do, not at the release.
        item.button?.sendAction(on: [.leftMouseDown])
        statusItem = item
        showWhetherEnabled()

        installSignalHandlers()
        // The settings are laid out now rather than at the first click: building them takes a quarter of a second
        // of the main thread, which also draws the cursor.
        DispatchQueue.main.async { [popover] in
            popover.contentViewController?.view.layoutSubtreeIfNeeded()
        }
        // Delivered at once, though this app is rarely the active one: that is when macOS would hold it back.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showSettings),
                                                            name: Self.showSettingsNotification, object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil)
        // A menu-bar app opens no window, so the first time the settings are shown to say where it went. Saving
        // them marks the first launch as done.
        if firstLaunch {
            SettingsStore.save(model.settings)
            showSettingsOnceInMenuBar(tries: 40)
        }
    }

    /// At launch macOS takes a moment to place the item in the menu bar: its window starts empty in a corner of the
    /// screen, then slides up into place. A popover hung from it before it gets there does not appear, or appears
    /// in the wrong place. So this waits until the window reaches the top of its screen, for two seconds at most.
    private func showSettingsOnceInMenuBar(tries: Int) {
        let item = statusItem?.button?.window
        let placed = item.map { $0.frame.height > 0 && $0.frame.maxY >= ($0.screen?.frame.maxY ?? .infinity) } ?? false
        guard tries > 0, !placed else { return showSettings() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            showSettingsOnceInMenuBar(tries: tries - 1)
        }
    }

    /// The icon in the menu bar is the app's drop, full while the liquid cursor is on and hollow while it is off.
    private func showWhetherEnabled() {
        withObservationTracking {
            statusItem?.button?.image = Self.menuBarIcon(filled: model.isEnabled)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.showWhetherEnabled() }
        }
    }

    /// The drop of the app's icon at menu bar size: a cursor's tip, its left side straight down and its right side
    /// at 45 degrees, ending round. A template image, so macOS tints it like the icons around it.
    private static func menuBarIcon(filled: Bool) -> NSImage {
        let outline = Drop.outline(radius: 3.8, steps: 48)
        let lineWidth: CGFloat = 1.3
        let inset = lineWidth / 2 + 0.5
        let size = NSSize(width: outline.map(\.x).max()! + 2 * inset, height: outline.map(\.y).max()! + 2 * inset)
        let image = NSImage(size: size, flipped: true) { _ in
            let drop = NSBezierPath()
            drop.move(to: CGPoint(x: inset, y: inset))
            for point in outline.dropFirst() {
                drop.line(to: CGPoint(x: point.x + inset, y: point.y + inset))
            }
            drop.close()
            drop.lineJoinStyle = .round
            NSColor.black.set()
            if filled {
                drop.fill()
            } else {
                drop.lineWidth = lineWidth
                drop.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = filled ? String(localized: "LiquidMouse, on")
            : String(localized: "LiquidMouse, off")
        return image
    }

    /// Opening the app again (from the Finder, Spotlight…) while it runs shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Turning the engine off gives the cursor back to the system.
        engine.isEnabled = false
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.close()
        } else {
            showSettings()
        }
    }

    @objc private func showSettings() {
        guard !popover.isShown, let button = statusItem?.button else { return }
        model.readLoginStatusInBackground()
        model.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
        // Closed at a click outside the app or when another app comes in front. A transient popover should do that
        // on its own; hung from a menu bar item it does not, on macOS 27 at least.
        outsideClicks = outsideClicks ?? NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }
        // Escape closes them too, as it does any popover that closes on its own.
        escapeKey = escapeKey ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.popover.isShown else { return event }
            self.popover.close()
            return nil
        }
    }

    private func clickedOutside() {
        // A click on the item itself is left to `togglePopover`, which would otherwise open the settings again.
        if statusItem?.button?.window?.frame.contains(NSEvent.mouseLocation) != true {
            popover.close()
        }
    }

    @objc private func applicationActivated(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if popover.isShown, application != .current {
            popover.close()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        outsideClicks.map(NSEvent.removeMonitor)
        outsideClicks = nil
        escapeKey.map(NSEvent.removeMonitor)
        escapeKey = nil
    }

    /// Ctrl-C in a terminal, or a plain kill, must go through a normal quit, or the cursor could stay hidden.
    private func installSignalHandlers() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}
