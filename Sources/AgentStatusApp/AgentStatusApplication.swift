import AppKit
import AgentStatusCore
import AgentStatusIntegration
import os

@main
enum AgentStatusApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        _ = delegate
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.tylerbartschi.agent-status", category: "app")
    private let preferences = AppPreferences()
    private let store = SessionStore()
    private let eventServer = SessionEventServer()
    private lazy var audioController = AudioController(preferences: preferences)
    private lazy var notchController = NotchPanelController(store: store)
    private lazy var hookSettings = HookSettingsModel(
        installer: HookInstaller(bundledHookURL: bundledHookURL)
    )
    private lazy var settingsController = SettingsWindowController(
        preferences: preferences,
        hookSettings: hookSettings
    )
    private var statusItem: NSStatusItem?

    private var bundledHookURL: URL {
        Bundle.module.url(forResource: "agent-status-hook", withExtension: "py")
            ?? Bundle.main.resourceURL?
                .appendingPathComponent("agent-status-hook.py")
            ?? Bundle.main.bundleURL.appendingPathComponent("agent-status-hook.py")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.onTransition = { [weak self] transition in
            self?.audioController.play(for: transition)
        }

        notchController.start()
        installStatusItem()

        do {
            try eventServer.start { [weak self] event in
                self?.store.process(event)
            }
        } catch {
            logger.error("Unable to start event server: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventServer.stop()
        notchController.stop()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "circle.grid.2x2.fill",
                accessibilityDescription: "Agent Status"
            )
        }

        let menu = NSMenu()
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let source = NSMenuItem(
            title: "View Source Code",
            action: #selector(openSource),
            keyEquivalent: ""
        )
        source.target = self
        menu.addItem(source)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Agent Status",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() {
        settingsController.showWindow()
    }

    @objc private func openSource() {
        NSWorkspace.shared.open(AppPreferences.sourceURL)
    }
}
