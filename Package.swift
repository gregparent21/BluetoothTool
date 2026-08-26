// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BluetoothTool",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BluetoothTool",
            path: "Sources/BluetoothTool",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOBluetooth"),
            ]
        )
    ]
)
