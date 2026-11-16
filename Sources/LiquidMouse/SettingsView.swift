import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// What the settings show and edit. A model of its own, not view state: the app delegate starts the engine from it
/// before the panel is ever shown, and the menu bar icon follows it. Every change goes to the engine and is saved.
@Observable
final class SettingsModel {
    @ObservationIgnored private let engine: Engine
    var isEnabled: Bool {
        didSet {
            engine.isEnabled = isEnabled
            SettingsStore.isEnabled = isEnabled
        }
    }
    var settings: Engine.Settings {
        didSet {
            engine.settings = settings
            SettingsStore.save(settings)
        }
    }
    /// Whether this macOS still offers the calls the engine needs.
    let isSupported: Bool
    private(set) var canSeeButtons = ElementProbe.isAllowed
    private(set) var reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private(set) var opensAtLogin = false
    private(set) var loginNeedsApproval = false
    private(set) var loginError: String?

    init(engine: Engine) {
        self.engine = engine
        isEnabled = SettingsStore.isEnabled
        settings = SettingsStore.load()
        isSupported = engine.isSupported
        engine.settings = settings
        engine.isEnabled = isEnabled
    }

    /// Catches up with what the user can change in System Settings while the panel is open.
    func refresh() {
        let allowed = ElementProbe.isAllowed
        if allowed != canSeeButtons { canSeeButtons = allowed }
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if calm != reducesMotion { reducesMotion = calm }
    }

    /// The login item as macOS has it. Read when the panel opens, not all the time: asking macOS about it reads the
    /// app's own files.
    func readLoginStatus() {
        show(SMAppService.mainApp.status)
    }

    /// The same without holding up the main thread, which draws the cursor: the question takes a frame or two.
    func readLoginStatusInBackground() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let status = SMAppService.mainApp.status
            await MainActor.run { self?.show(status) }
        }
    }

    private func show(_ status: SMAppService.Status) {
        let opens = status == .enabled || status == .requiresApproval
        if opens != opensAtLogin { opensAtLogin = opens }
        if (status == .requiresApproval) != loginNeedsApproval { loginNeedsApproval = status == .requiresApproval }
    }

    func setOpensAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginError = error.localizedDescription
        }
        // Shown as it really is: if macOS refused, the switch goes back.
        readLoginStatus()
    }

    func addExcludedApplications() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let self else { return }
                let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
                    .filter { $0 != appIdentifier }
                self.settings.excludedApplicationIDs = Array(Set(self.settings.excludedApplicationIDs + ids)).sorted()
            }
        }
    }

    func applicationName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// The settings, shown from the menu bar.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Liquid cursor", isOn: $model.isEnabled)
                    .disabled(!model.isSupported)
                if !model.isSupported {
                    Text("This version of macOS no longer offers the calls LiquidMouse needs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Shape", selection: $model.settings.body.form) {
                    ForEach(CursorForm.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Color", selection: $model.settings.body.appearance) {
                    ForEach(BodyLook.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                // A share of the usual size: it means the same for the dot and the arrow.
                slider("Size", $model.settings.body.dotRadius, in: 4...20) {
                    "\(Int(($0 / Glyph.designRadius * 100).rounded()))%"
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text(model.settings.body.appearance == .automatic
                     ? """
                       Automatic is light when macOS is dark, and dark when it is light. \
                       The size also follows the pointer size set in Accessibility.
                       """
                     : "The size also follows the pointer size set in Accessibility.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                slider("Trail length", $model.settings.body.trailLength, in: 0...400) {
                    $0 < 1 ? String(localized: "none") : String(format: "%.0f pt", $0)
                }
                slider("Trail speed", $model.settings.body.trailResponse, in: 20...240) {
                    switch $0 {
                    case ..<45: String(localized: "slow")
                    case ..<75: String(localized: "soft")
                    case ..<120: String(localized: "medium")
                    case ..<180: String(localized: "quick")
                    default: String(localized: "snappy")
                    }
                }
                slider("Bounce", $model.settings.body.bounce, in: 0...1) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                .disabled(model.reducesMotion)
                Toggle("Splash on click", isOn: $model.settings.body.splashes)
                    .disabled(model.reducesMotion)
                Toggle("Shrink when moving slowly", isOn: $model.settings.body.shrinksWhenAiming)
            } header: {
                Text("Motion")
            } footer: {
                if model.reducesMotion {
                    Text("Reduce Motion is on in Accessibility settings: no bounce and no splash.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section("Hiding") {
                Toggle("While typing", isOn: $model.settings.hidesWhileTyping)
                Picker("When still", selection: $model.settings.hidesWhenStill) {
                    ForEach(Engine.StillHiding.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.hidesWhenStill != .never {
                    slider("After", $model.settings.stillDelay, in: 1...30) { String(format: "%.0f s", $0) }
                }
            }
            Section {
                if !model.settings.excludedApplicationIDs.isEmpty {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(model.settings.excludedApplicationIDs, id: \.self) { id in
                                HStack {
                                    Text(verbatim: model.applicationName(id)).lineLimit(1)
                                    Spacer()
                                    Button {
                                        model.settings.excludedApplicationIDs.removeAll { $0 == id }
                                    } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(Text("Remove exclusion"))
                                }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(model.settings.excludedApplicationIDs.count) * 30, 120))
                }
                Button("Add app…") { model.addExcludedApplications() }
            } header: {
                Text("Use original cursor")
            } footer: {
                Text("Games are detected automatically. Add any other apps that should keep their own cursor.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Buttons") {
                if model.canSeeButtons {
                    Text("Buttons and links are recognized even where the app keeps the arrow.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("To recognize buttons, LiquidMouse needs the Accessibility permission.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") {
                        // Asking puts LiquidMouse in the list there, ready to be switched on; the first time macOS
                        // also shows its own prompt.
                        ElementProbe.askForPermission()
                        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                        if let url = URL(string: pane) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            Section {
                if Self.isTranslocated {
                    // Opened straight from a download, macOS runs it from a temporary copy: a login item would
                    // point to a place that is gone at the next start.
                    Text("To open it at login, move LiquidMouse to Applications and open it again.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle("Open at login",
                           isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                    if model.loginNeedsApproval {
                        Text("macOS asks you to approve it in System Settings, under Login Items.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = model.loginError {
                    Text("Could not change open at login: \(error)")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Restore default settings") { model.settings = Engine.Settings() }
                Button("Quit LiquidMouse") { NSApp.terminate(nil) }
                    // The app has no menu of its own, so the usual shortcut is given here.
                    .keyboardShortcut("q")
            } footer: {
                HStack {
                    Text(verbatim: "LiquidMouse \(Self.version) (\(Self.build))")
                    Spacer()
                    Link(destination: Self.project) { Text(verbatim: "GitHub") }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Keep the popover on screen; Form scrolls to the remaining controls on smaller displays.
        .frame(width: 410, height: min(720, max(360, (NSScreen.main?.visibleFrame.height ?? 800) - 80)))
        .onReceive(refresh) { _ in model.refresh() }
    }

    private static let isTranslocated = Bundle.main.bundlePath.contains("/AppTranslocation/")
    private static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    private static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    private static let project = URL(string: "https://github.com/BeniaminoNardone/LiquidMouse")!

    private func slider(_ title: LocalizedStringKey, _ value: Binding<Double>, in range: ClosedRange<Double>,
                        display: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                    // VoiceOver reads the value as shown beside the slider, not the slider's raw position.
                    .accessibilityLabel(title)
                    .accessibilityValue(display(value.wrappedValue))
                Text(display(value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

private extension CursorForm {
    var title: LocalizedStringKey {
        switch self {
        case .dot: "Dot"
        case .arrow: "Arrow"
        }
    }
}

private extension BodyLook {
    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

private extension Engine.StillHiding {
    var title: LocalizedStringKey {
        switch self {
        case .never: "Never"
        case .inFullScreen: "In full screen"
        case .always: "Always"
        }
    }
}
