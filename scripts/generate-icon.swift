#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Production rendering follows the approved native master in
// design/lighttable-v1.1/source/generate-identity.swift. Read the same geometry
// and sRGB colors from its specification rather than scaling a preview bitmap.
let arguments = CommandLine.arguments
let scriptURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
let projectURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outputURL = arguments.count > 1
    ? URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
    : projectURL.appendingPathComponent(".build/AppIcon", isDirectory: true)
let iconsetURL = outputURL.appendingPathComponent("Filmbox.iconset", isDirectory: true)

struct IconError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct IdentitySpecification: Decodable {
    struct Mark: Decodable {
        let rectangles: [[CGFloat]]
        let fixedBlueRectangleIndex: Int
        let fixedBlue: String
        let bodyOnLight: String
    }
    struct AppIcon: Decodable {
        let canvas: CGFloat
        let container: [CGFloat]
        let cornerRadius: CGFloat
        let containerOnLight: String
        let glyphOrigin: [CGFloat]
        let glyphScale: CGFloat
        let blueContainer: Bool
    }
    let version: String
    let mark: Mark
    let appIcon: AppIcon
}

let specificationURL = projectURL.appendingPathComponent("design/lighttable-v1.1/identity-spec.json")
let specification = try JSONDecoder().decode(IdentitySpecification.self, from: Data(contentsOf: specificationURL))
let expectedRectangles: [[CGFloat]] = [[0, 16, 24, 72], [32, 0, 24, 44], [32, 60, 24, 44], [64, 16, 24, 72]]
guard specification.version == "1.1", specification.mark.rectangles == expectedRectangles,
      specification.mark.fixedBlueRectangleIndex == 1,
      specification.mark.fixedBlue == "#315BFF", specification.mark.bodyOnLight == "#000000",
      specification.appIcon.canvas == 1024, specification.appIcon.container == [64, 64, 896, 896],
      specification.appIcon.cornerRadius == 208, specification.appIcon.glyphOrigin == [292, 252],
      specification.appIcon.glyphScale == 5, specification.appIcon.containerOnLight == "#F5F6F7",
      !specification.appIcon.blueContainer else {
    throw IconError(message: "应用图标规范与已确认的光桌 V1.1 不一致")
}

func color(_ hex: String) throws -> CGColor {
    guard hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else {
        throw IconError(message: "图标颜色不是有效的 sRGB 色值：\(hex)")
    }
    return CGColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: 1)
}

func rectangle(_ values: [CGFloat]) -> CGRect {
    CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
}

let background = try color(specification.appIcon.containerOnLight)
let blue = try color(specification.mark.fixedBlue)
let black = try color(specification.mark.bodyOnLight)
let container = rectangle(specification.appIcon.container)
let markRectangles = specification.mark.rectangles.map(rectangle)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func writePNG(size: Int, name: String) throws {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconError(message: "无法创建图标 sRGB 画布")
    }
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    // The identity specification uses a top-left origin, matching its SVG master.
    context.translateBy(x: 0, y: CGFloat(size))
    let scale = CGFloat(size) / specification.appIcon.canvas
    context.scaleBy(x: scale, y: -scale)
    context.setFillColor(background)
    context.addPath(CGPath(roundedRect: container,
                           cornerWidth: specification.appIcon.cornerRadius,
                           cornerHeight: specification.appIcon.cornerRadius,
                           transform: nil))
    context.fillPath()
    context.translateBy(x: specification.appIcon.glyphOrigin[0], y: specification.appIcon.glyphOrigin[1])
    context.scaleBy(x: specification.appIcon.glyphScale, y: specification.appIcon.glyphScale)
    for (index, rect) in markRectangles.enumerated() {
        context.setFillColor(index == specification.mark.fixedBlueRectangleIndex ? blue : black)
        context.fill(rect)
    }
    let url = iconsetURL.appendingPathComponent(name)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw IconError(message: "无法编码图标 PNG")
    }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [
        kCGImagePropertyPNGSoftware: "Filmbox production icon generator; identity V1.1"
    ]] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw IconError(message: "图标 PNG 写入失败") }
}

for size in [16, 32, 128, 256, 512] {
    try writePNG(size: size, name: "icon_\(size)x\(size).png")
    try writePNG(size: size * 2, name: "icon_\(size)x\(size)@2x.png")
}
let previewURL = outputURL.appendingPathComponent("Filmbox.png")
try Data(contentsOf: iconsetURL.appendingPathComponent("icon_512x512@2x.png"))
    .write(to: previewURL, options: .atomic)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", outputURL.appendingPathComponent("Filmbox.icns").path, iconsetURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { throw IconError(message: "iconutil 无法生成 icns 文件") }
print(outputURL.appendingPathComponent("Filmbox.icns").path)
