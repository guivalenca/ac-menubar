// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GuiCondicionado",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "GuiCondicionado", targets: ["GuiCondicionado"]),
        .executable(name: "actool", targets: ["actool"]),
        .library(name: "MideaKit", targets: ["MideaKit"]),
    ],
    targets: [
        .target(name: "MideaKit"),
        .executableTarget(name: "GuiCondicionado", dependencies: ["MideaKit"]),
        .executableTarget(name: "actool", dependencies: ["MideaKit"]),
        .testTarget(
            name: "MideaKitTests",
            dependencies: ["MideaKit"],
            resources: [.copy("Vectors.json")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
