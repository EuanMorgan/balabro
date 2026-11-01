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
]

#if os(macOS)
// The thin shell: file watching, the claude process, screen capture, the overlay.
targets.append(.executableTarget(name: "Balabro", dependencies: ["BalabroCore"]))
#endif

let package = Package(
    name: "Balabro",
    platforms: [.macOS(.v14)],
    targets: targets,
    swiftLanguageModes: [.v6]
)
