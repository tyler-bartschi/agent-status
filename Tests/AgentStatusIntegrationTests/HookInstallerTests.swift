import Foundation
import Testing
@testable import AgentStatusIntegration

@Suite("Hook installer")
struct HookInstallerTests {
    @Test func codexInstallPreservesConfigurationAndIsIdempotent() throws {
        try withFixture { fixture in
            let config = fixture.home.appendingPathComponent(".codex/hooks.json")
            try fixture.writeJSON([
                "hooks": [
                    "Stop": [[
                        "hooks": [[
                            "type": "command",
                            "command": "existing-tool"
                        ]]
                    ]]
                ],
                "unrelated": "preserved"
            ], to: config)

            try fixture.installer.install(.codex)
            try fixture.installer.install(.codex)

            let root = try fixture.readJSON(config)
            #expect(root["unrelated"] as? String == "preserved")
            let hooks = try #require(root["hooks"] as? [String: Any])
            let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
            #expect(stopGroups.count == 2)
            #expect(hooks["Interrupt"] != nil)
            #expect(hooks["SessionEnd"] != nil)
            #expect(fixture.ownedTimeout(for: "Interrupt", in: hooks) == 3)
            #expect(fixture.ownedTimeout(for: "SessionEnd", in: hooks) == 3)
            #expect(fixture.ownedTimeout(for: "Stop", in: hooks) == 5)
            #expect(fixture.ownedHandlerCount(in: hooks) == fixture.codexEventCount)
            #expect(try fixture.installer.isInstalled(.codex))
        }
    }

    @Test func claudeInstallAndUninstallPreserveUnrelatedHooks() throws {
        try withFixture { fixture in
            let config = fixture.home.appendingPathComponent(".claude/settings.json")
            try fixture.writeJSON([
                "theme": "dark",
                "hooks": [
                    "Stop": [[
                        "matcher": "existing",
                        "hooks": [[
                            "type": "command",
                            "command": "existing-tool"
                        ]]
                    ]]
                ]
            ], to: config)

            try fixture.installer.install(.claude)
            #expect(try fixture.installer.isInstalled(.claude))
            try fixture.installer.uninstall(.claude)

            let root = try fixture.readJSON(config)
            #expect(root["theme"] as? String == "dark")
            let hooks = try #require(root["hooks"] as? [String: Any])
            let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
            #expect(stopGroups.count == 1)
            #expect(fixture.ownedHandlerCount(in: hooks) == 0)
        }
    }

    @Test func claudeReinstallReplacesAsyncOwnedHandlerWithOrderedHandler() throws {
        try withFixture { fixture in
            let config = fixture.home.appendingPathComponent(".claude/settings.json")
            try fixture.writeJSON([
                "hooks": [
                    "Stop": [[
                        "hooks": [[
                            "type": "command",
                            "command": "old-hook \(HookInstaller.ownershipArgument)",
                            "async": true,
                            "timeout": 5
                        ]]
                    ]]
                ]
            ], to: config)

            #expect(try !fixture.installer.isInstalled(.claude))
            try fixture.installer.install(.claude)
            #expect(try fixture.installer.isInstalled(.claude))

            let root = try fixture.readJSON(config)
            let hooks = try #require(root["hooks"] as? [String: Any])
            let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
            let ownedHandlers = stopGroups.flatMap { group in
                (group["hooks"] as? [[String: Any]] ?? []).filter {
                    ($0["command"] as? String)?.contains(HookInstaller.ownershipArgument) == true
                }
            }
            let handler = try #require(ownedHandlers.only)
            #expect(handler["async"] == nil)
            #expect(handler["timeout"] as? Int == 5)
        }
    }

    @Test func duplicateOwnedHandlersAreReportedAsOutdatedAndDeduplicated() throws {
        try withFixture { fixture in
            try fixture.installer.install(.codex)
            let config = fixture.home.appendingPathComponent(".codex/hooks.json")
            var root = try fixture.readJSON(config)
            var hooks = try #require(root["hooks"] as? [String: Any])
            var stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
            stopGroups.append(try #require(stopGroups.last))
            hooks["Stop"] = stopGroups
            root["hooks"] = hooks
            try fixture.writeJSON(root, to: config)

            #expect(try !fixture.installer.isInstalled(.codex))

            try fixture.installer.install(.codex)

            #expect(try fixture.installer.isInstalled(.codex))
            let updatedRoot = try fixture.readJSON(config)
            let updatedHooks = try #require(updatedRoot["hooks"] as? [String: Any])
            #expect(fixture.ownedHandlerCount(for: "Stop", in: updatedHooks) == 1)
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-status-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hook = root.appendingPathComponent("agent-status-hook.py")
        try Data("#!/usr/bin/env python3\n".utf8).write(to: hook)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: hook.path
        )
        try body(Fixture(home: root, hook: hook))
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private struct Fixture {
    let home: URL
    let installer: HookInstaller
    let codexEventCount = 10

    init(home: URL, hook: URL) {
        self.home = home
        installer = HookInstaller(bundledHookURL: hook, homeDirectory: home)
    }

    func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    func readJSON(_ url: URL) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    func ownedHandlerCount(in hookMap: [String: Any]) -> Int {
        hookMap.values.reduce(into: 0) { total, value in
            guard let groups = value as? [[String: Any]] else { return }
            for group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else { continue }
                total += handlers.filter {
                    ($0["command"] as? String)?.contains(HookInstaller.ownershipArgument) == true
                }.count
            }
        }
    }

    func ownedHandlerCount(for event: String, in hookMap: [String: Any]) -> Int {
        guard let groups = hookMap[event] as? [[String: Any]] else { return 0 }
        return groups.reduce(into: 0) { total, group in
            guard let handlers = group["hooks"] as? [[String: Any]] else { return }
            total += handlers.filter {
                ($0["command"] as? String)?.contains(HookInstaller.ownershipArgument) == true
            }.count
        }
    }

    func ownedTimeout(for event: String, in hookMap: [String: Any]) -> Int? {
        guard let groups = hookMap[event] as? [[String: Any]] else { return nil }
        return groups
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .first {
                ($0["command"] as? String)?.contains(HookInstaller.ownershipArgument) == true
            }?["timeout"] as? Int
    }
}
