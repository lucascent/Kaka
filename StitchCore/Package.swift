// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StitchCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "StitchCore", targets: ["StitchCore"]),
        .library(name: "StitchWorkflow", targets: ["StitchWorkflow"]),
        .executable(name: "StitchDemo", targets: ["StitchDemo"])
    ],
    targets: [
        .target(name: "StitchCore"),
        .target(name: "StitchWorkflow", dependencies: ["StitchCore"]),
        .executableTarget(name: "StitchDemo", dependencies: ["StitchCore"]),
        .testTarget(name: "StitchCoreTests", dependencies: ["StitchCore"]),
        .testTarget(name: "StitchWorkflowTests", dependencies: ["StitchCore", "StitchWorkflow"])
    ],
    swiftLanguageModes: [.v6]
)
