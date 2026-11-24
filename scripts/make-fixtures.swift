#!/usr/bin/env swift

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Explicit development fixtures. The application never imports these automatically.
let projectURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    .deletingLastPathComponent().deletingLastPathComponent()
let timelineFixtures = CommandLine.arguments.contains("--timeline")
let rootURL = projectURL.appendingPathComponent(timelineFixtures ? ".build/TimelineFixtures" : ".build/Fixtures", isDirectory: true)
let fileManager = FileManager.default
try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

struct FixtureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func drawScene(in context: CGContext, width: Int, height: Int, style: Int, phase: CGFloat = 0) {
    let w = CGFloat(width)
    let h = CGFloat(height)
    let palette: [(CGColor, CGColor, CGColor, CGColor)] = [
        (rgb(0.88, 0.66, 0.49), rgb(0.33, 0.49, 0.55), rgb(0.15, 0.30, 0.35), rgb(0.99, 0.80, 0.52)),
        (rgb(0.63, 0.74, 0.69), rgb(0.30, 0.47, 0.43), rgb(0.13, 0.29, 0.27), rgb(0.88, 0.88, 0.72)),
        (rgb(0.63, 0.62, 0.77), rgb(0.31, 0.32, 0.50), rgb(0.16, 0.19, 0.30), rgb(0.97, 0.72, 0.59)),
        (rgb(0.91, 0.86, 0.72), rgb(0.55, 0.60, 0.45), rgb(0.24, 0.35, 0.28), rgb(0.98, 0.93, 0.69))
    ]
    let colors = palette[style % palette.count]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [colors.0, colors.1] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: .zero, options: [])

    let sunRadius = min(w, h) * 0.065
    context.setFillColor(colors.3)
    context.fillEllipse(in: CGRect(x: w * (0.69 + sin(phase) * 0.03), y: h * 0.66, width: sunRadius * 2, height: sunRadius * 2))

    context.setFillColor(colors.1)
    context.beginPath()
    context.move(to: CGPoint(x: -w * 0.1, y: h * 0.22))
    context.addLine(to: CGPoint(x: w * 0.23, y: h * 0.63))
    context.addLine(to: CGPoint(x: w * 0.54, y: h * 0.23))
    context.addLine(to: CGPoint(x: w * 0.77, y: h * 0.48))
    context.addLine(to: CGPoint(x: w * 1.1, y: h * 0.16))
    context.addLine(to: CGPoint(x: w * 1.1, y: 0))
    context.addLine(to: CGPoint(x: -w * 0.1, y: 0))
    context.closePath()
    context.fillPath()

    context.setFillColor(colors.2)
    context.beginPath()
    context.move(to: CGPoint(x: 0, y: h * 0.18))
    context.addCurve(to: CGPoint(x: w, y: h * 0.21), control1: CGPoint(x: w * 0.28, y: h * (0.40 + sin(phase) * 0.02)), control2: CGPoint(x: w * 0.73, y: -h * 0.05))
    context.addLine(to: CGPoint(x: w, y: 0))
    context.addLine(to: .zero)
    context.closePath()
    context.fillPath()

    context.setStrokeColor(rgb(1, 1, 1, 0.075))
    context.setLineWidth(max(1, w / 1400))
    for index in 0..<18 {
        let y = h * (0.06 + CGFloat(index) * 0.014)
        let offset = sin(CGFloat(index) * 1.7 + phase) * w * 0.05
        context.move(to: CGPoint(x: w * 0.51 + offset, y: y))
        context.addLine(to: CGPoint(x: w * 0.75 + offset, y: y))
        context.strokePath()
    }
}

func makeImage(relativePath: String, width: Int, height: Int, style: Int, day: Int) throws {
    let fileManager = FileManager.default
    let url = rootURL.appendingPathComponent(relativePath)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw FixtureError(message: "无法创建图片画布")
    }
    drawScene(in: context, width: width, height: height, style: style)
    guard let image = context.makeImage() else { throw FixtureError(message: "无法生成图片") }
    let type = url.pathExtension == "png" ? UTType.png.identifier : UTType.jpeg.identifier
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
        throw FixtureError(message: "无法写入图片")
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    let start = calendar.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 16, minute: 28))!
    let capture = calendar.date(byAdding: .day, value: day - 1, to: start)!
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    let date = formatter.string(from: capture)
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.88,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: date,
            kCGImagePropertyExifFNumber: 2.8,
            kCGImagePropertyExifExposureTime: 1.0 / 250.0,
            kCGImagePropertyExifISOSpeedRatings: [200],
            kCGImagePropertyExifFocalLength: 35.0
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Filmbox Fixture Generator",
            kCGImagePropertyTIFFModel: "Generated test image",
            kCGImagePropertyTIFFDateTime: date
        ]
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw FixtureError(message: "图片编码失败") }
    let fixtureDate = capture
    try fileManager.setAttributes([.creationDate: fixtureDate, .modificationDate: fixtureDate], ofItemAtPath: url.path)
}

func makeVideo(relativePath: String, style: Int) async throws {
    let fileManager = FileManager.default
    let url = rootURL.appendingPathComponent(relativePath)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    let width = 640
    let height = 360
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ])
    guard writer.canAdd(input) else { throw FixtureError(message: "无法添加视频轨道") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? FixtureError(message: "视频编码无法开始") }
    writer.startSession(atSourceTime: .zero)

    for frame in 0..<60 {
        let deadline = Date().addingTimeInterval(15)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? FixtureError(message: "视频编码中断") }
            guard Date() < deadline else { throw FixtureError(message: "视频编码等待超时") }
            try await Task.sleep(for: .milliseconds(2))
        }
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
        guard result == kCVReturnSuccess, let buffer else { throw FixtureError(message: "无法创建视频帧") }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            throw FixtureError(message: "无法绘制视频帧")
        }
        drawScene(in: context, width: width, height: height, style: style, phase: CGFloat(frame) / 60 * .pi * 2)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 20)) else {
            throw writer.error ?? FixtureError(message: "无法写入视频帧")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? FixtureError(message: "无法完成视频编码") }
}

let images: [(String, Int, Int, Int, Int)] = [
    ("海岸/暮色.jpg", 1600, 1067, 0, 1),
    ("海岸/海边/潮汐.png", 1400, 1000, 0, 2),
    ("山间/清晨.jpg", 1200, 1600, 1, 6),
    ("山间/雾.jpg", 1600, 1067, 1, 7),
    ("日常/窗边.png", 1600, 1200, 3, 12),
    ("日常/夜色.jpg", 1280, 960, 2, 16),
    ("日常/归途.jpg", 1600, 900, 3, 18)
]
for (path, width, height, style, day) in images {
    try makeImage(relativePath: path, width: width, height: height, style: style, day: day)
}
if timelineFixtures {
    let sizes = [(1600, 1067), (800, 1200), (1400, 1000), (1600, 900), (1800, 600)]
    for index in 0..<60 {
        let size = sizes[index % sizes.count]
        try makeImage(relativePath: "时序/片段-\(String(format: "%02d", index + 1)).jpg", width: size.0, height: size.1, style: index, day: 1 + (index / 5) * 7)
    }
}
try await makeVideo(relativePath: "海岸/流动的光.mov", style: 0)
try await makeVideo(relativePath: "山间/雨幕.mov", style: 1)
print("已生成 \(timelineFixtures ? 67 : 7) 张图片、2 段 H.264 短视频：\(rootURL.path)")
