// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MLXUtilsLibrary",
    platforms: [
      .iOS(.v18), .macOS(.v15)
    ],
    products: [
        .library(
            name: "MLXUtilsLibrary",
            targets: ["MLXUtilsLibrary"]
        ),
    ],
    dependencies: [
        .package(path: "../ZIPFoundation"),
        .package(url: "https://github.com/PrismML-Eng/mlx-swift.git", from: "0.29.1")
    ],
    targets: [
        .target(
            name: "MLXUtilsLibrary",
            dependencies: [
                "ZIPFoundation",
                .product(name: "MLX", package: "mlx-swift")
            ]
        )
    ]
)
