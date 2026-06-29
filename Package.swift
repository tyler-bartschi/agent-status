// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentStatus",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AgentStatusCore", targets: ["AgentStatusCore"]),
        .executable(name: "AgentStatusApp", targets: ["AgentStatusApp"])
    ],
    targets: [
        .target(name: "AgentStatusCore"),
        .executableTarget(
            name: "AgentStatusApp",
            dependencies: ["AgentStatusCore"],
            resources: [
                .copy("Hooks/agent-status-hook.py")
            ]
        ),
        .testTarget(
            name: "AgentStatusCoreTests",
            dependencies: ["AgentStatusCore"]
        )
    ]
)
