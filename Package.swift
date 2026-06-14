// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "conso",
    platforms: [.macOS("14.0")],
    products: [
        // Library only — the SwiftUI app lives in the Xcode app target (conso/conso.xcodeproj),
        // which links this package and references the UI sources in Sources/conso/.
        .library(name: "ConsoCore", targets: ["ConsoCore"]),
    ],
    targets: [
        // C shim for the private IOHIDEventSystem temperature-sensor API.
        .target(name: "CSensors", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "ConsoCore", dependencies: ["CSensors"]),
        .testTarget(name: "ConsoCoreTests", dependencies: ["ConsoCore"]),
    ]
)
