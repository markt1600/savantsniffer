// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SavantSniffer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SavantSniffer",
            path: "Sources/SavantSniffer",
            resources: [.process("Resources")]
        )
    ]
)
