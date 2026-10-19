// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ac-menubar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ac-menubar", targets: ["ACMenubar"]),
        .executable(name: "actool", targets: ["actool"]),
        .library(name: "MideaKit", targets: ["MideaKit"]),
    ],
    targets: [
        .target(name: "MideaKit"),
        .executableTarget(name: "ACMenubar", dependencies: ["MideaKit"]),
        .executableTarget(name: "actool", dependencies: ["MideaKit"]),
        .testTarget(
            name: "MideaKitTests",
            dependencies: ["MideaKit"],
            resources: [.copy("Vectors.json")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
