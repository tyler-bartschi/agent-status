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

private struct Fixture {
    let home: URL
    let installer: HookInstaller
    let codexEventCount = 8

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
}
