import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppPreferences: ObservableObject {
    static let sourceURL = URL(string: "https://github.com/tyler-bartschi/agent-status")!

    static let systemSoundNames = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    @Published var waitingSoundEnabled: Bool {
        didSet { defaults.set(waitingSoundEnabled, forKey: Keys.waitingSoundEnabled) }
    }

    @Published var finishedSoundEnabled: Bool {
        didSet { defaults.set(finishedSoundEnabled, forKey: Keys.finishedSoundEnabled) }
    }

    @Published var waitingSoundName: String {
        didSet { defaults.set(waitingSoundName, forKey: Keys.waitingSoundName) }
    }

    @Published var finishedSoundName: String {
        didSet { defaults.set(finishedSoundName, forKey: Keys.finishedSoundName) }
    }

    @Published var volume: Double {
        didSet {
            volume = min(max(volume, 0), 1)
            defaults.set(volume, forKey: Keys.volume)
        }
    }

    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginAvailable = false
    @Published private(set) var launchAtLoginError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        waitingSoundEnabled = defaults.object(forKey: Keys.waitingSoundEnabled) as? Bool ?? true
        finishedSoundEnabled = defaults.object(forKey: Keys.finishedSoundEnabled) as? Bool ?? true
        waitingSoundName = defaults.string(forKey: Keys.waitingSoundName) ?? "Ping"
        finishedSoundName = defaults.string(forKey: Keys.finishedSoundName) ?? "Glass"
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 0.5
        refreshLaunchAtLogin()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard launchAtLoginAvailable else { return }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        // SwiftPM executables have no stable bundle registration. The control
        // becomes available in the packaged .app produced by scripts/bundle.sh.
        launchAtLoginAvailable =
            Bundle.main.bundleURL.pathExtension == "app" &&
            Bundle.main.bundleIdentifier != nil
        launchAtLogin = launchAtLoginAvailable && SMAppService.mainApp.status == .enabled
    }

    private enum Keys {
        static let waitingSoundEnabled = "agentStatus.audio.waiting.enabled"
        static let finishedSoundEnabled = "agentStatus.audio.finished.enabled"
        static let waitingSoundName = "agentStatus.audio.waiting.name"
        static let finishedSoundName = "agentStatus.audio.finished.name"
        static let volume = "agentStatus.audio.volume"
    }
}
