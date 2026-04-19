#!/usr/bin/env swift

import AppKit
import Foundation

struct RuntimeRect: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct RuntimeMetadata: Decodable {
    let mainWindowFrame: RuntimeRect?
    let titlebarHeight: Double?
    let sidebarVisible: Bool
    let sidebarWidth: Double
}

struct LayoutPixelRect: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct LayoutSelectedPanel: Decodable {
    let panelType: String
    let viewFrame: LayoutPixelRect?
}

struct LayoutResponse: Decodable {
    let selectedPanels: [LayoutSelectedPanel]
}

struct Arguments {
    let imagePath: String
    let runtimeMetadataPath: String
    let layoutDebugPath: String
    let outputDirectory: String
}

enum CropError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case imageLoadFailed(String)
    case cgImageUnavailable(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .invalidArguments(let message),
                .imageLoadFailed(let message),
                .cgImageUnavailable(let message),
                .writeFailed(let message):
            return message
        }
    }
}

func parseArguments() throws -> Arguments {
    var imagePath: String?
    var runtimeMetadataPath: String?
    var layoutDebugPath: String?
    var outputDirectory: String?

    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--image":
            imagePath = iterator.next()
        case "--runtime-metadata":
            runtimeMetadataPath = iterator.next()
        case "--layout-debug":
            layoutDebugPath = iterator.next()
        case "--output-dir":
            outputDirectory = iterator.next()
        default:
            throw CropError.invalidArguments("Unknown argument: \(argument)")
        }
    }

    guard let imagePath, let runtimeMetadataPath, let layoutDebugPath, let outputDirectory else {
        throw CropError.invalidArguments(
            "Usage: macos-crop-png.swift --image <png> --runtime-metadata <json> --layout-debug <json> --output-dir <dir>"
        )
    }

    return Arguments(
        imagePath: imagePath,
        runtimeMetadataPath: runtimeMetadataPath,
        layoutDebugPath: layoutDebugPath,
        outputDirectory: outputDirectory
    )
}

func decodeJSON<T: Decodable>(_ type: T.Type, path: String) throws -> T {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(type, from: data)
}

func cropRect(
    from globalRect: LayoutPixelRect,
    windowFrame: RuntimeRect,
    imageSize: CGSize
) -> CGRect {
    let x = globalRect.x - windowFrame.x
    let y = (windowFrame.y + windowFrame.height) - (globalRect.y + globalRect.height)
    let rect = CGRect(x: x, y: y, width: globalRect.width, height: globalRect.height)
    return rect.integral.intersection(CGRect(origin: .zero, size: imageSize))
}

func sidebarRect(metadata: RuntimeMetadata, imageSize: CGSize) -> CGRect? {
    guard metadata.sidebarVisible else { return nil }
    let width = min(CGFloat(metadata.sidebarWidth), imageSize.width)
    return CGRect(x: 0, y: 0, width: width, height: imageSize.height).integral
}

func titlebarRect(metadata: RuntimeMetadata, imageSize: CGSize) -> CGRect? {
    guard let titlebarHeight = metadata.titlebarHeight, titlebarHeight > 0 else { return nil }
    let height = min(CGFloat(titlebarHeight), imageSize.height)
    return CGRect(x: 0, y: 0, width: imageSize.width, height: height).integral
}

func writeCrop(
    named name: String,
    rect: CGRect?,
    cgImage: CGImage,
    outputDirectory: String
) throws {
    guard let rect, rect.width > 1, rect.height > 1 else { return }
    guard let cropped = cgImage.cropping(to: rect) else {
        throw CropError.cgImageUnavailable("Failed to crop \(name) at rect \(rect)")
    }
    let representation = NSBitmapImageRep(cgImage: cropped)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw CropError.writeFailed("Failed to create PNG data for \(name)")
    }
    let outputPath = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        .appendingPathComponent("crop-\(name).png", isDirectory: false)
    try data.write(to: outputPath)
}

func run() throws {
    let arguments = try parseArguments()
    let metadata = try decodeJSON(RuntimeMetadata.self, path: arguments.runtimeMetadataPath)
    let layout = try decodeJSON(LayoutResponse.self, path: arguments.layoutDebugPath)

    let imageURL = URL(fileURLWithPath: arguments.imagePath)
    guard let image = NSImage(contentsOf: imageURL) else {
        throw CropError.imageLoadFailed("Failed to load image at \(arguments.imagePath)")
    }
    var rect = CGRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        throw CropError.cgImageUnavailable("Failed to create CGImage for \(arguments.imagePath)")
    }

    let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: arguments.outputDirectory, isDirectory: true),
        withIntermediateDirectories: true
    )

    try writeCrop(named: "titlebar", rect: titlebarRect(metadata: metadata, imageSize: imageSize), cgImage: cgImage, outputDirectory: arguments.outputDirectory)
    try writeCrop(named: "sidebar", rect: sidebarRect(metadata: metadata, imageSize: imageSize), cgImage: cgImage, outputDirectory: arguments.outputDirectory)

    if let windowFrame = metadata.mainWindowFrame {
        let terminalRect = layout.selectedPanels
            .first(where: { $0.panelType == "terminal" })
            .flatMap(\.viewFrame)
            .map { cropRect(from: $0, windowFrame: windowFrame, imageSize: imageSize) }
        let browserRect = layout.selectedPanels
            .first(where: { $0.panelType == "browser" })
            .flatMap(\.viewFrame)
            .map { cropRect(from: $0, windowFrame: windowFrame, imageSize: imageSize) }
        try writeCrop(named: "terminal", rect: terminalRect, cgImage: cgImage, outputDirectory: arguments.outputDirectory)
        try writeCrop(named: "browser", rect: browserRect, cgImage: cgImage, outputDirectory: arguments.outputDirectory)
    }
}

do {
    try run()
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
