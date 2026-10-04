// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AWSPlatform",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0"),
        .package(url: "https://github.com/soto-project/soto-core.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AWSPlatform",
            dependencies: [
                .product(name: "SotoCore", package: "soto-core"),
                .product(name: "SotoEC2", package: "soto"),
                .product(name: "SotoLambda", package: "soto"),
                .product(name: "SotoS3", package: "soto"),
                .product(name: "SotoSTS", package: "soto"),
                .product(name: "SotoCostExplorer", package: "soto"),
                .product(name: "SotoCloudWatch", package: "soto"),
                .product(name: "SotoCloudWatchLogs", package: "soto"),
                .product(name: "SotoSNS", package: "soto"),
                .product(name: "SotoHealth", package: "soto"),
                .product(name: "SotoRoute53", package: "soto"),
            ]
        ),
        .testTarget(
            name: "AWSPlatformTests",
            dependencies: ["AWSPlatform"]
        ),
    ]
)
