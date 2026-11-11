// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhoneLinkMac",
    platforms: [.macOS("15.0")],
    targets: [
        // A virtual display for using a phone as a second screen. CoreGraphics only offers it to Objective-C.
        .target(name: "VirtualDisplay", path: "Sources/VirtualDisplay",
                linkerSettings: [.linkedFramework("CoreGraphics")]),
        .target(name: "PowerKit", path: "Sources/PowerKit", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "PhoneLinkMac", dependencies: ["VirtualDisplay", "PowerKit"], path: "Sources/PhoneLinkMac"),
        // The small root helper for charging control. See Sources/PowerHelper/main.swift for what it may do.
        .executableTarget(name: "dysklink-power", dependencies: ["PowerKit"], path: "Sources/PowerHelper"),
        // Firefox's native messaging host for the DyskLink YouTube extension.
        .executableTarget(name: "dysklink-browser-host", path: "Sources/BrowserHost"),
    ]
)
