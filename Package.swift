// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TaskManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "task-manager", targets: ["TaskManagerCLI"]),
        .library(name: "TaskManagerCore", targets: ["TaskManagerCore"]),
        .library(name: "TaskManagerPersistence", targets: ["TaskManagerPersistence"]),
        .library(name: "CodexTransport", targets: ["CodexTransport"]),
        .library(name: "GitHubIntegration", targets: ["GitHubIntegration"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CLocalSupport", linkerSettings: [.linkedLibrary("ncurses")]),
        .target(name: "TaskManagerCore"),
        .target(name: "TaskManagerPersistence", dependencies: ["TaskManagerCore", "CSQLite"]),
        .target(name: "CodexTransport", dependencies: ["TaskManagerCore"]),
        .target(name: "GitHubIntegration", dependencies: ["TaskManagerCore"]),
        .target(name: "SlackIntegration", dependencies: ["TaskManagerCore"]),
        .target(name: "TaskManagerRuntime", dependencies: ["TaskManagerCore", "TaskManagerPersistence", "CodexTransport", "GitHubIntegration", "SlackIntegration", "CLocalSupport"]),
        .target(name: "TaskManagerTUI", dependencies: ["TaskManagerCore", "TaskManagerPersistence", "TaskManagerRuntime", "CLocalSupport"]),
        .executableTarget(name: "TaskManagerCLI", dependencies: ["TaskManagerCore", "TaskManagerPersistence", "CodexTransport", "GitHubIntegration", "TaskManagerRuntime", "TaskManagerTUI", "SlackIntegration"]),
        .testTarget(name: "TaskManagerTests", dependencies: ["TaskManagerCore", "TaskManagerPersistence", "CodexTransport", "GitHubIntegration", "TaskManagerRuntime", "TaskManagerTUI", "SlackIntegration"]),
    ]
)
