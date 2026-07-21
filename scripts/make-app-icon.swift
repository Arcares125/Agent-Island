#!/usr/bin/env swift

import AppKit
import Foundation

struct IconRendition {
    let pixels: Int
    let fileName: String
}

let renditions = [
    IconRendition(pixels: 16, fileName: "icon_16x16.png"),
    IconRendition(pixels: 32, fileName: "icon_16x16@2x.png"),
    IconRendition(pixels: 32, fileName: "icon_32x32.png"),
    IconRendition(pixels: 64, fileName: "icon_32x32@2x.png"),
    IconRendition(pixels: 128, fileName: "icon_128x128.png"),
    IconRendition(pixels: 256, fileName: "icon_128x128@2x.png"),
    IconRendition(pixels: 256, fileName: "icon_256x256.png"),
    IconRendition(pixels: 512, fileName: "icon_256x256@2x.png"),
    IconRendition(pixels: 512, fileName: "icon_512x512.png"),
    IconRendition(pixels: 1_024, fileName: "icon_512x512@2x.png")
]

guard CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write(
        Data("Usage: make-app-icon.swift INPUT_PNG OUTPUT_ICONSET OUTPUT_ICNS\n".utf8)
    )
    exit(64)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let icnsURL = URL(fileURLWithPath: CommandLine.arguments[3])
guard let sourceImage = NSImage(contentsOf: inputURL) else {
    FileHandle.standardError.write(Data("Could not read input image.\n".utf8))
    exit(65)
}

do {
    try FileManager.default.createDirectory(
        at: outputURL,
        withIntermediateDirectories: true
    )

    for rendition in renditions {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: rendition.pixels,
            pixelsHigh: rendition.pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.fileWriteUnknown)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let destinationRect = NSRect(
            x: 0,
            y: 0,
            width: rendition.pixels,
            height: rendition.pixels
        )
        NSColor.clear.setFill()
        destinationRect.fill()
        sourceImage.draw(
            in: destinationRect,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try pngData.write(
            to: outputURL.appendingPathComponent(rendition.fileName),
            options: .atomic
        )
    }

    let icnsChunks = [
        (type: "ic04", fileName: "icon_16x16.png"),
        (type: "ic11", fileName: "icon_16x16@2x.png"),
        (type: "ic05", fileName: "icon_32x32.png"),
        (type: "ic12", fileName: "icon_32x32@2x.png"),
        (type: "ic07", fileName: "icon_128x128.png"),
        (type: "ic13", fileName: "icon_128x128@2x.png"),
        (type: "ic08", fileName: "icon_256x256.png"),
        (type: "ic14", fileName: "icon_256x256@2x.png"),
        (type: "ic09", fileName: "icon_512x512.png"),
        (type: "ic10", fileName: "icon_512x512@2x.png")
    ]
    let chunkData = try icnsChunks.map { chunk in
        (type: chunk.type, data: try Data(contentsOf: outputURL.appendingPathComponent(chunk.fileName)))
    }
    let totalLength = 8 + chunkData.reduce(0) { $0 + 8 + $1.data.count }
    guard totalLength <= Int(UInt32.max) else {
        throw CocoaError(.fileWriteUnknown)
    }

    var icnsData = Data("icns".utf8)
    appendBigEndian(UInt32(totalLength), to: &icnsData)
    for chunk in chunkData {
        icnsData.append(Data(chunk.type.utf8))
        appendBigEndian(UInt32(8 + chunk.data.count), to: &icnsData)
        icnsData.append(chunk.data)
    }
    try icnsData.write(to: icnsURL, options: .atomic)
} catch {
    FileHandle.standardError.write(
        Data("Could not create app icon renditions: \(error.localizedDescription)\n".utf8)
    )
    exit(74)
}

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
        data.append(contentsOf: bytes)
    }
}
