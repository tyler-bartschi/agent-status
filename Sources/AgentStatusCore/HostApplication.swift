import Foundation

/// Applications that can originate an agent session.
public enum HostApplication: String, Codable, CaseIterable, Hashable, Sendable {
    case codexDesktop
    case codexCLI
    case claudeDesktop
    case claudeCLI

    public var displayName: String {
        switch self {
        case .codexDesktop:
            "Codex"
        case .codexCLI:
            "Codex CLI"
        case .claudeDesktop:
            "Claude"
        case .claudeCLI:
            "Claude CLI"
        }
    }
}
