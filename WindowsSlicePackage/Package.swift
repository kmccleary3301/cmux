// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WindowsSlicePackage",
    products: [
        .executable(name: "cmux-windows-slice", targets: ["WindowsSliceApp"])
    ],
    targets: [
        .executableTarget(
            name: "WindowsSliceApp",
            path: "Sources/WindowsSliceApp"
        )
    ]
)