// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FleetView",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "FleetView",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/FleetView"
        )
    ]
)
