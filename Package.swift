// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LimitDashboard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LimitDashboard", targets: ["LimitDashboard"])
    ],
    targets: [
        .executableTarget(
            name: "LimitDashboard",
            path: "Sources/LimitDashboard",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "LimitDashboardTests",
            dependencies: ["LimitDashboard"],
            path: "Tests/LimitDashboardTests"
        )
    ]
)
