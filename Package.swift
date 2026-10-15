// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Findling", platforms: [.macOS(.v14)], products: [.executable(name: "Findling", targets: ["Findling"])], targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "FindlingCore", dependencies: ["CSQLite"]),
    .executableTarget(name: "Findling", dependencies: ["FindlingCore"]),
    .testTarget(name: "FindlingCoreTests", dependencies: ["FindlingCore"])
])
