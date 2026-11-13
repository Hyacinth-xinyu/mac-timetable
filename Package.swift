// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TimetableApp",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TimetableApp", targets: ["TimetableApp"])],
    targets: [
        .executableTarget(name: "TimetableApp"),
        .testTarget(name: "TimetableAppTests", dependencies: ["TimetableApp"])
    ]
)
