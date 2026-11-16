@preconcurrency import ApplicationServices
import AppKit
import Synchronization

/// Asks the app under the pointer, through the Accessibility API, whether the pointer is over something clickable.
///
/// Only the kind of element is read (button, link…), never its title or content. The question
/// goes to another app and can be slow, so it is asked on a queue of its own, one at a time, with a short timeout.
nonisolated final class ElementProbe: Sendable {
    /// Elements the pointer should be precise over. A label or an icon inside one counts too, so the search climbs a
    /// few parents from the element actually hit.
    private static let clickableRoles: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle", "AXLink",
        "AXMenuBarItem", "AXIncrementor",
    ]
    private static let parentsToClimb = 3
    /// Seconds to wait for the other app's answer. An app that is busy should not hold the cursor up.
    private static let timeout: Float = 0.05

    private let queue = DispatchQueue(label: "LiquidMouse.accessibility", qos: .userInteractive)
    private let inFlight = Atomic<Bool>(false)
    private nonisolated(unsafe) let systemWide = AXUIElementCreateSystemWide()

    init() {
        AXUIElementSetMessagingTimeout(systemWide, Self.timeout)
    }

    /// Whether macOS lets this app use the Accessibility API.
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Asks macOS for the permission: it adds LiquidMouse to the list in System Settings, ready to be switched on,
    /// and the first time shows its own prompt. Only when the user asks for it, never on its own.
    static func askForPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// What was found under the pointer.
    struct Finding: Sendable {
        /// Nil when the app under the pointer did not answer.
        var clickable: Bool?
        var role: String?
    }

    /// Looks up the element at `point` (global coordinates, origin at the top left of the main screen) and calls
    /// `answer` with what it found, on the main thread. Skipped while a previous question is still out: returns
    /// whether it was asked.
    @discardableResult
    func lookUp(at point: CGPoint, answer: @escaping @MainActor @Sendable (Finding) -> Void) -> Bool {
        guard !inFlight.exchange(true, ordering: .acquiringAndReleasing) else { return false }
        queue.async { [self] in
            let finding = find(at: point)
            inFlight.store(false, ordering: .releasing)
            DispatchQueue.main.async { answer(finding) }
        }
        return true
    }

    private func find(at point: CGPoint) -> Finding {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit
        else { return Finding() }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == getpid() {
            // Our own windows: the panel. Nothing to adapt to there.
            return Finding(clickable: false)
        }
        let hitRole = role(of: element)
        for level in 0...Self.parentsToClimb {
            // Each question is a message to the other app: the element hit is asked once.
            if let role = level == 0 ? hitRole : role(of: element), Self.clickableRoles.contains(role) {
                return Finding(clickable: true, role: role)
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { break }
            element = parent as! AXUIElement
        }
        return Finding(clickable: false, role: hitRole)
    }

    private func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
