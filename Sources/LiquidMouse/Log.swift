import Foundation
import os

/// The app's bundle identifier, also when it runs as a bare binary (`swift run`, the tests), which has none.
nonisolated let appIdentifier = Bundle.main.bundleIdentifier ?? "io.github.beniaminonardone.LiquidMouse"

/// What the app notes about itself while it runs. Lifecycle events (stepping aside, restarts, stalls) are notices,
/// kept on disk; frequent ones (a button under the pointer, an unknown cursor) are info, shown only while streaming.
/// To read them, filter Console by the subsystem, or run
/// `/usr/bin/log stream --level info --predicate 'subsystem == "io.github.beniaminonardone.LiquidMouse"'`.
nonisolated let logger = Logger(subsystem: appIdentifier, category: "cursor")
