// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TCLimate",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TCLimate", targets: ["TCLMenuBar"]), .library(name: "TCLCore", targets: ["TCLCore"])],
    targets: [
        .target(name: "TCLCore"),
        .executableTarget(name: "TCLMenuBar", dependencies: ["TCLCore"])
    ],
    swiftLanguageModes: [.v5]
)
