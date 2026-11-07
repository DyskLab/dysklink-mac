// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhoneLinkMac",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "PhoneLinkMac", path: "Sources/PhoneLinkMac")
    ]
)
