// swift-tools-version:5.9

import PackageDescription

let swiftSettings: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency=complete"),
                                     .enableExperimentalFeature("NoncopyableGenerics"),
                                     .enableExperimentalFeature("MoveOnlyPartialConsumption"),
                                    ]

let package = Package(
    name: "swift-aws-lambda-runtime",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        // this library exports `AWSLambdaRuntimeCore` and adds Foundation convenience methods
        .library(name: "AWSLambdaRuntime", targets: ["AWSLambdaRuntime"]),
        // this has all the main functionality for lambda and it does not link Foundation
        .library(name: "AWSLambdaRuntimeCore", targets: ["AWSLambdaRuntimeCore"]),
        // plugin to package the lambda, creating an archive that can be uploaded to AWS
        .plugin(name: "AWSLambdaPackager", targets: ["AWSLambdaPackager"]),
        // for testing only
        .library(name: "AWSLambdaTesting", targets: ["AWSLambdaTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "2.58.0")),
        .package(url: "https://github.com/apple/swift-log.git", .upToNextMajor(from: "1.4.2")),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        .target(name: "AWSLambdaRuntime", dependencies: [
                .byName(name: "AWSLambdaRuntimeCore"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(name: "AWSLambdaRuntimeCore", dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ],
            swiftSettings: swiftSettings
        ),
        .plugin(
            name: "AWSLambdaPackager",
            capability: .command(
                intent: .custom(
                    verb: "archive",
                    description: "Archive the Lambda binary and prepare it for uploading to AWS. Requires docker on macOS or non Amazonlinux 2 distributions."
                )
            )
        ),
        .testTarget(name: "AWSLambdaRuntimeCoreTests", dependencies: [
                .byName(name: "AWSLambdaRuntimeCore"),
                .product(name: "NIOTestUtils", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "AWSLambdaRuntimeTests", dependencies: [
                .byName(name: "AWSLambdaRuntimeCore"),
                .byName(name: "AWSLambdaRuntime"),
            ],
            swiftSettings: swiftSettings
        ),
        // testing helper
        .target(name: "AWSLambdaTesting", dependencies: [
                .byName(name: "AWSLambdaRuntime"),
                .product(name: "NIO", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "AWSLambdaTestingTests", dependencies: [
                .byName(name: "AWSLambdaTesting")
            ],
            swiftSettings: swiftSettings
        ),
        // for perf testing
        .executableTarget(name: "MockServer", dependencies: [
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIO", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
