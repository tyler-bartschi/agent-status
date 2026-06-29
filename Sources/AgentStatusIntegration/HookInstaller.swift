import Foundation

public enum HookProvider: String, CaseIterable, Sendable {
    case codex
    case claude
}

public struct HookInstallationStatus: Equatable, Sendable {
    public let codexInstalled: Bool
    public let claudeInstalled: Bool

    public init(codexInstalled: Bool, claudeInstalled: Bool) {
        self.codexInstalled = codexInstalled
        self.claudeInstalled = claudeInstalled
    }
}

/// Installs the bundled adapter and merges only Agent Status-owned hook
/// handlers into provider configuration.
public struct HookInstaller {
    public enum InstallerError: LocalizedError {
        case invalidConfiguration(URL)
        case missingBundledHook(URL)

        public var errorDescription: String? {
            switch self {
            case let .invalidConfiguration(url):
                "Hook configuration is not a JSON object: \(url.path)"
            case let .missingBundledHook(url):
                "The bundled Agent Status hook is missing: \(url.path)"
            }
        }
    }

    public static let ownershipArgument = "--agent-status-owner=v1"

    public let homeDirectory: URL
    public let bundledHookURL: URL
    public let installedHookURL: URL

    private let fileManager: FileManager

    public init(
        bundledHookURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.bundledHookURL = bundledHookURL
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.installedHookURL = homeDirectory
            .appendingPathComponent("Library/Application Support/AgentStatus/Hooks", isDirectory: true)
            .appendingPathComponent("agent-status-hook.py")
    }

    public func install(_ provider: HookProvider) throws {
        try installHookExecutable()

        let configurationURL = configurationURL(for: provider)
        var root = try readObject(at: configurationURL)
        var hookMap = hooks(in: root, for: provider)
        let command = hookCommand(for: provider)

        for event in events(for: provider) {
            var groups = hookMap[event] as? [[String: Any]] ?? []
            if !containsOwnedHandler(in: groups) {
                groups.append([
                    "hooks": [handler(command: command, provider: provider)]
                ])
            }
            hookMap[event] = groups
        }

        setHooks(hookMap, in: &root, for: provider)
        try write(root, to: configurationURL)
    }

    public func uninstall(_ provider: HookProvider) throws {
        let configurationURL = configurationURL(for: provider)
        guard fileManager.fileExists(atPath: configurationURL.path) else {
            return
        }

        var root = try readObject(at: configurationURL)
        var hookMap = hooks(in: root, for: provider)

        for event in Array(hookMap.keys) {
            guard let groups = hookMap[event] as? [[String: Any]] else {
                continue
            }

            let remainingGroups = groups.compactMap { group -> [String: Any]? in
                var group = group
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    return group
                }
                let remainingHandlers = handlers.filter { !isOwnedHandler($0) }
                guard !remainingHandlers.isEmpty else {
                    return nil
                }
                group["hooks"] = remainingHandlers
                return group
            }

            if remainingGroups.isEmpty {
                hookMap.removeValue(forKey: event)
            } else {
                hookMap[event] = remainingGroups
            }
        }

        setHooks(hookMap, in: &root, for: provider)
        try write(root, to: configurationURL)
    }

    public func installationStatus() throws -> HookInstallationStatus {
        HookInstallationStatus(
            codexInstalled: try isInstalled(.codex),
            claudeInstalled: try isInstalled(.claude)
        )
    }

    public func isInstalled(_ provider: HookProvider) throws -> Bool {
        let url = configurationURL(for: provider)
        guard
            fileManager.isExecutableFile(atPath: installedHookURL.path),
            fileManager.fileExists(atPath: url.path)
        else {
            return false
        }

        let root = try readObject(at: url)
        let hookMap = hooks(in: root, for: provider)
        return events(for: provider).allSatisfy { event in
            guard let groups = hookMap[event] as? [[String: Any]] else {
                return false
            }
            return containsOwnedHandler(in: groups)
        }
    }

    public func configurationURL(for provider: HookProvider) -> URL {
        switch provider {
        case .codex:
            homeDirectory.appendingPathComponent(".codex/hooks.json")
        case .claude:
            homeDirectory.appendingPathComponent(".claude/settings.json")
        }
    }

    private func installHookExecutable() throws {
        guard fileManager.isReadableFile(atPath: bundledHookURL.path) else {
            throw InstallerError.missingBundledHook(bundledHookURL)
        }

        let directory = installedHookURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if fileManager.fileExists(atPath: installedHookURL.path) {
            try fileManager.removeItem(at: installedHookURL)
        }
        try fileManager.copyItem(at: bundledHookURL, to: installedHookURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: installedHookURL.path
        )
    }

    private func hookCommand(for provider: HookProvider) -> String {
        let escapedPath = installedHookURL.path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escapedPath)' --provider \(provider.rawValue) \(Self.ownershipArgument)"
    }

    private func handler(command: String, provider: HookProvider) -> [String: Any] {
        switch provider {
        case .codex:
            [
                "type": "command",
                "command": command,
                "timeout": 5
            ]
        case .claude:
            [
                "type": "command",
                "command": command,
                "async": true,
                "timeout": 5
            ]
        }
    }

    private func events(for provider: HookProvider) -> [String] {
        switch provider {
        case .codex:
            [
                "PermissionRequest", "PostCompact", "PostToolUse", "PreCompact",
                "PreToolUse", "SessionStart", "Stop", "UserPromptSubmit"
            ]
        case .claude:
            [
                "UserPromptSubmit", "PreToolUse", "PostToolUse",
                "PostToolUseFailure", "PermissionRequest", "Notification",
                "SubagentStart", "SubagentStop", "PreCompact", "PostCompact",
                "SessionStart", "Stop", "StopFailure", "SessionEnd"
            ]
        }
    }

    private func containsOwnedHandler(in groups: [[String: Any]]) -> Bool {
        groups.contains { group in
            guard let handlers = group["hooks"] as? [[String: Any]] else {
                return false
            }
            return handlers.contains(where: isOwnedHandler)
        }
    }

    private func isOwnedHandler(_ handler: [String: Any]) -> Bool {
        guard let command = handler["command"] as? String else {
            return false
        }
        return command.split(separator: " ").contains(Substring(Self.ownershipArgument))
    }

    private func hooks(
        in root: [String: Any],
        for provider: HookProvider
    ) -> [String: Any] {
        switch provider {
        case .codex:
            root["hooks"] as? [String: Any] ?? [:]
        case .claude:
            root["hooks"] as? [String: Any] ?? [:]
        }
    }

    private func setHooks(
        _ hooks: [String: Any],
        in root: inout [String: Any],
        for provider: HookProvider
    ) {
        switch provider {
        case .codex:
            root["hooks"] = hooks
        case .claude:
            root["hooks"] = hooks
        }
    }

    private func readObject(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw InstallerError.invalidConfiguration(url)
        }
        return object
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
