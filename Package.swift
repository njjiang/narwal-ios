// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "FreoCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FreoCore", targets: ["FreoCore"])],
    targets: [
        .target(name: "FreoCore", path: "FreoControl/Core", linkerSettings: [.linkedLibrary("z")]),
        .testTarget(name: "FreoCoreTests", dependencies: ["FreoCore"], path: "Tests/FreoCoreTests")
    ]
)
