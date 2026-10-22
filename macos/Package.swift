// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WiFiSwitch",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WiFiSwitch", targets: ["WiFiSwitch"])],
    targets: [
        .target(name: "WiFiSwitchCore"),
        .executableTarget(name: "WiFiSwitch", dependencies: ["WiFiSwitchCore"]),
        .testTarget(name: "WiFiSwitchCoreTests", dependencies: ["WiFiSwitchCore"]),
        .testTarget(name: "WiFiSwitchAppTests", dependencies: ["WiFiSwitch", "WiFiSwitchCore"])
    ]
)
