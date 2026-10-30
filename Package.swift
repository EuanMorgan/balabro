// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Balabro",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: save decoding, decisions, the coach state machine, prompts, CLI wire format.
        // No AppKit, no Process, no file watching. Everything here is tested with literal values.
        .target(name: "BalabroCore"),
        // The thin shell: file watching, the claude process, screen capture, the overlay.
        .executableTarget(name: "Balabro", dependencies: ["BalabroCore"]),
        .testTarget(
            name: "BalabroCoreTests",
            dependencies: ["BalabroCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
