import CoreGraphics
import Foundation

/// Keeps track of the asynchronous Accessibility hit tests: which one is current, and what its answer was.
struct ButtonProbeState {
    struct Target: Equatable {
        var location: CGPoint
        var application: pid_t?
    }

    struct Request {
        let target: Target
        let revision: UInt64
    }

    private var target: Target?
    private var revision: UInt64 = 0
    private var lastRequestedTarget: Target?
    private var lastRequestTime = -Double.infinity
    private(set) var overClickable = false

    mutating func observe(_ target: Target?) {
        guard target != self.target else { return }
        revision &+= 1
        // Keep the last successful answer while travelling within one app, until the next hit test answers.
        // Moving to another app, or to a place where buttons are not looked for, starts again from no button.
        if target == nil || target?.application != self.target?.application {
            overClickable = false
        }
        self.target = target
    }

    mutating func invalidate() {
        revision &+= 1
        target = nil
        lastRequestedTarget = nil
        lastRequestTime = -.infinity
        overClickable = false
    }

    func request(now: Double) -> Request? {
        guard let target, now - lastRequestTime >= 0.04,
              target != lastRequestedTarget || now - lastRequestTime >= 0.5 else { return nil }
        return Request(target: target, revision: revision)
    }

    /// Records a request only once it has really been sent (one may already be waiting for its answer).
    mutating func didRequest(_ request: Request, now: Double) {
        lastRequestedTarget = request.target
        lastRequestTime = now
    }

    @discardableResult
    mutating func accept(_ clickable: Bool?, for request: Request) -> Bool {
        guard request.revision == revision, request.target == target else { return false }
        // An app that stops answering must not leave an old "button" answer in place forever.
        overClickable = clickable ?? false
        return true
    }
}
