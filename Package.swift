// swift-tools-version: 6.2
import PackageDescription

var targets: [Target] = [
    // Pure logic: save decoding, decisions, the coach state machine, prompts, CLI wire format.
    // No AppKit, no Process, no file watching. Everything here is tested with literal values.
    .target(name: "BalabroCore"),
    .testTarget(
        name: "BalabroCoreTests",
        dependencies: ["BalabroCore"],
        resources: [.copy("Fixtures")]
    ),
    // The portable shell both apps use: the runtimes, the claude and bot processes, the save watcher.
    .target(name: "BalabroEngine", dependencies: ["BalabroCore"]),
    .testTarget(name: "BalabroEngineTests", dependencies: ["BalabroEngine"]),
]

#if os(macOS)
// The Mac face: screen capture, the overlay, the hotkey, the updater.
targets.append(.executableTarget(name: "Balabro", dependencies: ["BalabroCore", "BalabroEngine"]))
#endif

let package = Package(
    name: "Balabro",
    platforms: [.macOS(.v14)],
    targets: targets,
    swiftLanguageModes: [.v6]
)
