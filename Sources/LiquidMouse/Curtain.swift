import AppKit

/// Takes our cursor off the screen from any thread, for when the main thread that draws it has stopped answering
/// and would otherwise leave it frozen in place.
nonisolated final class Curtain: @unchecked Sendable {
    private let lock = NSLock()
    private var layers: [CALayer] = []

    /// The root layers of the overlay windows, the ones to hide.
    func cover(_ layers: [CALayer]) {
        lock.withLock { self.layers = layers }
    }

    /// Hides the overlays. Core Animation accepts changes from any thread inside an explicit transaction; the main
    /// thread, which normally owns these layers, is stuck and not touching them.
    func drop() {
        let layers = lock.withLock { self.layers }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers.forEach { $0.isHidden = true }
        CATransaction.commit()
        CATransaction.flush()
    }
}
