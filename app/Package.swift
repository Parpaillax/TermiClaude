// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TermiClaude",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TermiClaude",
            path: "Sources/TermiClaude",
            resources: [.process("Resources")]
        )
    ]
)
