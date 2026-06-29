// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentStatus",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AgentStatusCore", targets: ["AgentStatusCore"]),
        .library(name: "AgentStatusIntegration", targets: ["AgentStatusIntegration"]),
        .executable(name: "AgentStatusApp", targets: ["AgentStatusApp"])
    ],
    targets: [
        .target(name: "AgentStatusCore"),
        .target(
            name: "AgentStatusIntegration",
            dependencies: ["AgentStatusCore"]
        ),
        .executableTarget(
            name: "AgentStatusApp",
            dependencies: ["AgentStatusCore", "AgentStatusIntegration"],
            resources: [
                .copy("Hooks/agent-status-hook.py")
            ]
        ),
        .testTarget(
            name: "AgentStatusCoreTests",
            dependencies: ["AgentStatusCore"]
        ),
        .testTarget(
            name: "AgentStatusIntegrationTests",
            dependencies: ["AgentStatusIntegration"]
        )
    ],
    swiftLanguageModes: [.v5]
)
