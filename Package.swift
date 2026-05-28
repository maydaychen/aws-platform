// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AWSPlatform",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AWSPlatform",
            dependencies: [
                .product(name: "SotoCore", package: "soto"),
                .product(name: "SotoEC2", package: "soto"),
                .product(name: "SotoLambda", package: "soto"),
                .product(name: "SotoS3", package: "soto"),
            ]
        ),
    ]
)
