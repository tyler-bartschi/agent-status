import AppKit
import AgentStatusCore
import AgentStatusIntegration
import SwiftUI

@MainActor
final class HookSettingsModel: ObservableObject {
    @Published private(set) var codexInstalled = false
    @Published private(set) var claudeInstalled = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isUpdating = false

    private let installer: HookInstaller

    init(installer: HookInstaller) {
        self.installer = installer
        refresh()
    }

    func refresh() {
        do {
            let status = try installer.installationStatus()
            codexInstalled = status.codexInstalled
            claudeInstalled = status.claudeInstalled
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func install(_ provider: HookProvider) {
        perform {
            try installer.install(provider)
        }
    }

    func uninstall(_ provider: HookProvider) {
        perform {
            try installer.uninstall(provider)
        }
    }

    private func perform(_ operation: () throws -> Void) {
        isUpdating = true
        defer {
            isUpdating = false
            refresh()
        }
        do {
            try operation()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        preferences: AppPreferences,
        hookSettings: HookSettingsModel,
        audioController: AudioController
    ) {
        let root = SettingsView(
            preferences: preferences,
            hookSettings: hookSettings,
            audioController: audioController
        )
        let hostingController = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Agent Status Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 480))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindow() {
        window?.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        super.showWindow(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var hookSettings: HookSettingsModel
    let audioController: AudioController

    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Launch on Login",
                    isOn: Binding(
                        get: { preferences.launchAtLogin },
                        set: { enabled in
                            preferences.setLaunchAtLogin(enabled)
                        }
                    )
                )
                .disabled(!preferences.launchAtLoginAvailable)

                if !preferences.launchAtLoginAvailable {
                    Text("Launch on Login is available in the bundled app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let error = preferences.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Audio") {
                SoundSettingRow(
                    title: "Waiting",
                    enabled: $preferences.waitingSoundEnabled,
                    soundName: $preferences.waitingSoundName,
                    preview: { audioController.preview(.waiting) }
                )
                SoundSettingRow(
                    title: "Finished",
                    enabled: $preferences.finishedSoundEnabled,
                    soundName: $preferences.finishedSoundName,
                    preview: { audioController.preview(.finished) }
                )
                HStack {
                    Text("Volume")
                    Slider(value: $preferences.volume, in: 0...1)
                    Text(preferences.volume, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }

            Section("Hooks") {
                HookSettingRow(
                    name: "Codex",
                    installed: hookSettings.codexInstalled,
                    disabled: hookSettings.isUpdating,
                    install: { hookSettings.install(.codex) },
                    uninstall: { hookSettings.uninstall(.codex) }
                )
                HookSettingRow(
                    name: "Claude Code",
                    installed: hookSettings.claudeInstalled,
                    disabled: hookSettings.isUpdating,
                    install: { hookSettings.install(.claude) },
                    uninstall: { hookSettings.uninstall(.claude) }
                )
                if let error = hookSettings.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("About") {
                Link("View Source Code", destination: AppPreferences.sourceURL)
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(minWidth: 440, minHeight: 440)
        .onAppear {
            preferences.refreshLaunchAtLogin()
            hookSettings.refresh()
        }
    }
}

private struct SoundSettingRow: View {
    let title: String
    @Binding var enabled: Bool
    @Binding var soundName: String
    let preview: () -> Void

    var body: some View {
        HStack {
            Toggle(title, isOn: $enabled)
            Spacer()
            Picker("Sound", selection: $soundName) {
                ForEach(AppPreferences.systemSoundNames, id: \.self) {
                    Text($0)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .onChange(of: soundName) { _ in
                preview()
            }
            Button(action: preview) {
                Image(systemName: "play.circle.fill")
            }
            .buttonStyle(.plain)
            .help("Play \(title) sound")
            .accessibilityLabel("Play \(title) sound")
        }
    }
}

private struct HookSettingRow: View {
    let name: String
    let installed: Bool
    let disabled: Bool
    let install: () -> Void
    let uninstall: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(installed ? "Installed" : "Not installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(installed ? "Uninstall" : "Install") {
                if installed {
                    uninstall()
                } else {
                    install()
                }
            }
            .disabled(disabled)
        }
    }
}
