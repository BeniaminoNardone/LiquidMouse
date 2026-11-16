import AppKit

/// The few undocumented WindowServer calls LiquidMouse depends on.
/// Symbols are resolved at runtime, so a macOS release that drops one disables the feature instead of breaking launch.
nonisolated enum WindowServer {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SetConnectionPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private typealias CursorSeedFn = @convention(c) () -> Int32
    private typealias CursorIsVisibleFn = @convention(c) () -> UInt32

    private static let mainConnection = symbol("CGSMainConnectionID", MainConnectionFn.self)
    private static let setConnectionProperty = symbol("CGSSetConnectionProperty", SetConnectionPropertyFn.self)
    private static let currentCursorSeed = symbol("CGSCurrentCursorSeed", CursorSeedFn.self)
    private static let cursorIsVisible = symbol("CGCursorIsVisible", CursorIsVisibleFn.self)
    /// The call the Dock uses to take the cursor over while the pointer is on it.
    private typealias DockCursorOverrideFn = @convention(c) (Int32, Bool) -> Int32
    private static let dockCursorOverride = symbol("SLSSetDockCursorOverride", DockCursorOverrideFn.self)
    private typealias ScreenWatcherFn = @convention(c) () -> Bool
    private static let screenWatcherPresent = symbol("SLSIsScreenWatcherPresent", ScreenWatcherFn.self)
    private typealias CursorScaleFn = @convention(c) (Int32, UnsafeMutablePointer<Float>) -> Int32
    private static let cursorScale = symbol("SLSGetCursorScale", CursorScaleFn.self)

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let address = dlsym(rtldDefault, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    /// Lets this process set and hide the cursor while another app is frontmost.
    static func allowBackgroundCursorControl() -> Bool {
        guard let mainConnection, let setConnectionProperty else { return false }
        let connection = mainConnection()
        return setConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }

    /// Goes up by one every time any process changes the system cursor image.
    static var cursorSeed: Int32? { currentCursorSeed?() }

    static var isCursorVisible: Bool? { cursorIsVisible.map { $0() != 0 } }

    /// Whether something records or shares the screen right now: a screen recording, a video call…
    static var isScreenRecorded: Bool? { screenWatcherPresent?() }

    /// The pointer size chosen in the accessibility settings, 1 being the standard size.
    static var pointerScale: Double? {
        guard let cursorScale, let mainConnection else { return nil }
        var scale: Float = 1
        guard cursorScale(mainConnection(), &scale) == 0, scale.isFinite, scale > 0 else { return nil }
        return Double(scale)
    }

    /// Takes (or gives back) the cursor override the Dock otherwise holds while the pointer is over it. Returns the
    /// error code, or nil when the call does not exist.
    static func setDockCursorOverride(_ on: Bool) -> Int32? {
        guard let dockCursorOverride, let mainConnection else { return nil }
        return dockCursorOverride(mainConnection(), on)
    }
}
