#!/usr/bin/env swift

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// All artwork is drawn from geometry and native font outlines. No source image
// or font file is loaded, modified, embedded, or redistributed.
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let rootURL = sourceURL.deletingLastPathComponent().deletingLastPathComponent()
let assetURL = rootURL.appendingPathComponent("assets", isDirectory: true)
try FileManager.default.createDirectory(at: assetURL, withIntermediateDirectories: true)

enum Ink {
    static let blue = "315BFF"
    static let logoBlack = "000000"
    static let logoWhite = "FFFFFF"
    static let surface = "17191D"
    static let raised = "22252B"
    static let border = "363A42"
    static let white = "F5F6F7"
    static let secondary = "A9AFBA"
    static let canvas = "181818"
    static let light = "ECECEC"
}

let markSize = CGSize(width: 88, height: 104)
let markRects = [
    CGRect(x: 0, y: 16, width: 24, height: 72),
    CGRect(x: 32, y: 0, width: 24, height: 44),
    CGRect(x: 32, y: 60, width: 24, height: 44),
    CGRect(x: 64, y: 16, width: 24, height: 72)
]

struct ArtError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func cgColor(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    let value = UInt32(hex, radix: 16) ?? 0
    return CGColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: alpha)
}

func decimal(_ value: CGFloat) -> String {
    if abs(value.rounded() - value) < 0.00001 { return String(Int(value.rounded())) }
    var result = String(format: "%.4f", Double(value))
    while result.last == "0" { result.removeLast() }
    if result.last == "." { result.removeLast() }
    return result
}

func svgPath(_ path: CGPath) -> String {
    var pieces: [String] = []
    func point(_ value: CGPoint) -> String { "\(decimal(value.x)) \(decimal(value.y))" }
    path.applyWithBlock { pointer in
        let element = pointer.pointee
        switch element.type {
        case .moveToPoint: pieces.append("M\(point(element.points[0]))")
        case .addLineToPoint: pieces.append("L\(point(element.points[0]))")
        case .addQuadCurveToPoint: pieces.append("Q\(point(element.points[0])) \(point(element.points[1]))")
        case .addCurveToPoint: pieces.append("C\(point(element.points[0])) \(point(element.points[1])) \(point(element.points[2]))")
        case .closeSubpath: pieces.append("Z")
        @unknown default: break
        }
    }
    return pieces.joined(separator: " ")
}

struct Lettering: @unchecked Sendable {
    let path: CGPath
    let width: CGFloat
    let height: CGFloat
}

func outline(_ string: String, fontName: String, size: CGFloat, tracking: CGFloat = 0) -> Lettering {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTKernAttributeName as String): tracking
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    let composite = CGMutablePath()
    if let runs = CTLineGetGlyphRuns(line) as? [CTRun] {
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for index in 0..<count {
                if let glyphPath = CTFontCreatePathForGlyph(font, glyphs[index], nil) {
                    let transform = CGAffineTransform(translationX: positions[index].x, y: positions[index].y)
                    composite.addPath(glyphPath, transform: transform)
                }
            }
        }
    }
    let bounds = composite.boundingBoxOfPath
    let transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -bounds.minX, ty: bounds.maxY)
    let normalized = CGMutablePath()
    normalized.addPath(composite, transform: transform)
    return Lettering(path: normalized, width: bounds.width, height: bounds.height)
}

func drawText(_ context: CGContext, _ string: String, at point: CGPoint, size: CGFloat,
              font: String = "HelveticaNeue", color: String = Ink.surface, tracking: CGFloat = 0) {
    let letters = outline(string, fontName: font, size: size, tracking: tracking)
    context.saveGState()
    context.translateBy(x: point.x, y: point.y)
    context.setFillColor(cgColor(color))
    context.addPath(letters.path)
    context.fillPath()
    context.restoreGState()
}

func drawMark(_ context: CGContext, x: CGFloat, y: CGFloat, scale: CGFloat, color: String) {
    context.saveGState()
    context.translateBy(x: x, y: y)
    context.scaleBy(x: scale, y: scale)
    for (index, rect) in markRects.enumerated() {
        context.setFillColor(cgColor(index == 1 ? Ink.blue : color))
        context.fill(rect)
    }
    context.restoreGState()
}

func rectElements(color: String) -> String {
    markRects.enumerated().map { index, rect in
        let fill = index == 1 ? "#\(Ink.blue)" : (color == "currentColor" ? color : "#\(color)")
        return "<rect x=\"\(decimal(rect.minX))\" y=\"\(decimal(rect.minY))\" width=\"\(decimal(rect.width))\" height=\"\(decimal(rect.height))\" fill=\"\(fill)\"/>"
    }.joined(separator: "\n")
}

func writeSVG(_ name: String, size: CGSize, body: String) throws {
    let document = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="\(decimal(size.width))" height="\(decimal(size.height))" viewBox="0 0 \(decimal(size.width)) \(decimal(size.height))" role="img" aria-label="Filmbox">
    \(body)
    </svg>
    """
    try document.write(to: assetURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

func writePNG(to url: URL, size: CGSize, pixelWidth: Int, pixelHeight: Int? = nil,
              drawing: (CGContext) -> Void) throws {
    let height = pixelHeight ?? Int((CGFloat(pixelWidth) * size.height / size.width).rounded())
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixelWidth, height: height, bitsPerComponent: 8,
                                  bytesPerRow: pixelWidth * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw ArtError(message: "无法创建 sRGB 画布")
    }
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: CGFloat(pixelWidth) / size.width, y: -CGFloat(height) / size.height)
    drawing(context)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw ArtError(message: "无法编码 PNG")
    }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGSoftware: "Filmbox native identity generator"]] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ArtError(message: "PNG 写入失败") }
}

let englishFont = "HelveticaNeue-Bold"
let chineseFont = "PingFangSC-Medium"
for name in [englishFont, chineseFont] {
    let font = CTFontCreateWithName(name as CFString, 100, nil)
    guard (CTFontCopyPostScriptName(font) as String) == name else {
        throw ArtError(message: "字体不可用：\(name)")
    }
}
let wordmark = outline("filmbox", fontName: englishFont, size: 100, tracking: -1.5)
let chinese = outline("菲林盒", fontName: chineseFont, size: 22, tracking: 2.2)
let englishY: CGFloat = 4
let chineseY: CGFloat = 104 - chinese.height
let lockupSize = CGSize(width: 120 + wordmark.width, height: 104)

func drawLockup(_ context: CGContext, x: CGFloat, y: CGFloat, scale: CGFloat,
                markColor: String = Ink.logoBlack, textColor: String = Ink.logoBlack) {
    context.saveGState()
    context.translateBy(x: x, y: y)
    context.scaleBy(x: scale, y: scale)
    drawMark(context, x: 0, y: 0, scale: 1, color: markColor)
    context.setFillColor(cgColor(textColor))
    let lettering = CGMutablePath()
    lettering.addPath(wordmark.path, transform: CGAffineTransform(translationX: 120, y: englishY))
    lettering.addPath(chinese.path, transform: CGAffineTransform(translationX: 120, y: chineseY))
    context.addPath(lettering)
    context.fillPath()
    context.restoreGState()
}

func lockupElements(markColor: String, textColor: String) -> String {
    """
    <g id="mark">
    \(rectElements(color: markColor))
    </g>
    <g id="wordmark" fill="#\(textColor)">
    <path transform="translate(120 \(decimal(englishY)))" d="\(svgPath(wordmark.path))"/>
    <path transform="translate(120 \(decimal(chineseY)))" d="\(svgPath(chinese.path))"/>
    </g>
    """
}

for (suffix, color) in [("light", Ink.logoBlack), ("dark", Ink.logoWhite)] {
    try writeSVG("logo-mark-\(suffix).svg", size: markSize, body: rectElements(color: color))
    try writePNG(to: assetURL.appendingPathComponent("logo-mark-\(suffix).png"), size: markSize, pixelWidth: 1408) { context in
        drawMark(context, x: 0, y: 0, scale: 1, color: color)
    }
}
try writeSVG("logo-mark-adaptive.svg", size: markSize, body: rectElements(color: "currentColor"))
for (name, markColor, textColor) in [
    ("logo-lockup-light", Ink.logoBlack, Ink.logoBlack),
    ("logo-lockup-dark", Ink.logoWhite, Ink.logoWhite)
] {
    try writeSVG("\(name).svg", size: lockupSize, body: lockupElements(markColor: markColor, textColor: textColor))
    try writePNG(to: assetURL.appendingPathComponent("\(name).png"), size: lockupSize, pixelWidth: Int((lockupSize.width * 4).rounded())) { context in
        drawLockup(context, x: 0, y: 0, scale: 1, markColor: markColor, textColor: textColor)
    }
}
for (suffix, color) in [("black", Ink.logoBlack), ("white", Ink.logoWhite)] {
    try writeSVG("logo-wordmark-\(suffix).svg", size: CGSize(width: wordmark.width, height: wordmark.height),
                 body: "<path fill=\"#\(color)\" d=\"\(svgPath(wordmark.path))\"/>")
    try writePNG(to: assetURL.appendingPathComponent("logo-wordmark-\(suffix).png"), size: CGSize(width: wordmark.width, height: wordmark.height), pixelWidth: Int((wordmark.width * 6).rounded())) { context in
        context.setFillColor(cgColor(color))
        context.addPath(wordmark.path)
        context.fillPath()
    }
}

let iconSize = CGSize(width: 1024, height: 1024)
let iconRect = CGRect(x: 64, y: 64, width: 896, height: 896)
let iconRadius: CGFloat = 208
let iconMarkScale: CGFloat = 5
let iconMarkX: CGFloat = (1024 - 88 * iconMarkScale) / 2
let iconMarkY: CGFloat = (1024 - 104 * iconMarkScale) / 2

func drawIcon(_ context: CGContext, background: String? = Ink.white, body: String = Ink.logoBlack) {
    if let background {
        context.setFillColor(cgColor(background))
        context.addPath(CGPath(roundedRect: iconRect, cornerWidth: iconRadius, cornerHeight: iconRadius, transform: nil))
        context.fillPath()
    }
    drawMark(context, x: iconMarkX, y: iconMarkY, scale: iconMarkScale, color: body)
}
func iconElements(background: String?, body: String) -> String {
    let container = background.map { "<rect x=\"64\" y=\"64\" width=\"896\" height=\"896\" rx=\"208\" fill=\"#\($0)\"/>" } ?? ""
    return """
\(container)
<g transform="translate(\(decimal(iconMarkX)) \(decimal(iconMarkY))) scale(5)">
\(rectElements(color: body))
</g>
"""
}
for (name, background, body) in [("app-icon", Ink.white, Ink.logoBlack), ("app-icon-dark", Ink.surface, Ink.logoWhite)] {
    try writeSVG("\(name).svg", size: iconSize, body: iconElements(background: background, body: body))
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        let filename = size == 1024 ? "\(name).png" : "\(name)-\(size).png"
        try writePNG(to: assetURL.appendingPathComponent(filename), size: iconSize, pixelWidth: size) { context in
            drawIcon(context, background: background, body: body)
        }
    }
}
for (name, body) in [("app-icon-transparent-light", Ink.logoBlack), ("app-icon-transparent-dark", Ink.logoWhite)] {
    try writeSVG("\(name).svg", size: iconSize, body: iconElements(background: nil, body: body))
    try writePNG(to: assetURL.appendingPathComponent("\(name).png"), size: iconSize, pixelWidth: 1024) { context in
        drawIcon(context, background: nil, body: body)
    }
}

func rule(_ context: CGContext, from: CGPoint, to: CGPoint, color: String = "C8CBCD", width: CGFloat = 1) {
    context.setStrokeColor(cgColor(color))
    context.setLineWidth(width)
    context.move(to: from)
    context.addLine(to: to)
    context.strokePath()
}

func section(_ context: CGContext, _ title: String, x: CGFloat, y: CGFloat) {
    drawText(context, title, at: CGPoint(x: x, y: y), size: 14, font: "HelveticaNeue-Medium", tracking: 1.3)
}

func dimension(_ context: CGContext, from: CGPoint, to: CGPoint, label: String, labelPoint: CGPoint) {
    rule(context, from: from, to: to, color: "7D8490", width: 0.8)
    if from.y == to.y {
        rule(context, from: CGPoint(x: from.x, y: from.y - 4), to: CGPoint(x: from.x, y: from.y + 4), color: "7D8490", width: 0.8)
        rule(context, from: CGPoint(x: to.x, y: to.y - 4), to: CGPoint(x: to.x, y: to.y + 4), color: "7D8490", width: 0.8)
    } else {
        rule(context, from: CGPoint(x: from.x - 4, y: from.y), to: CGPoint(x: from.x + 4, y: from.y), color: "7D8490", width: 0.8)
        rule(context, from: CGPoint(x: to.x - 4, y: to.y), to: CGPoint(x: to.x + 4, y: to.y), color: "7D8490", width: 0.8)
    }
    drawText(context, label, at: labelPoint, size: 13, font: "HelveticaNeue-Medium", color: "656D79")
}

let previewURL = rootURL.appendingPathComponent("00-logo-preview.png")
try writePNG(to: previewURL, size: CGSize(width: 1600, height: 800), pixelWidth: 1600, pixelHeight: 800) { context in
    context.setFillColor(cgColor(Ink.light))
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
    context.setFillColor(cgColor(Ink.surface))
    context.fill(CGRect(x: 800, y: 0, width: 800, height: 800))
    drawText(context, "FILMBOX / LIGHT TABLE", at: CGPoint(x: 60, y: 48), size: 15, font: "HelveticaNeue-Medium", color: Ink.logoBlack, tracking: 1.5)
    drawText(context, "V1.1", at: CGPoint(x: 1460, y: 48), size: 15, font: "HelveticaNeue-Medium", color: Ink.logoWhite, tracking: 1.5)
    drawLockup(context, x: 86, y: 185, scale: 1.34)
    drawLockup(context, x: 886, y: 185, scale: 1.34, markColor: Ink.logoWhite, textColor: Ink.logoWhite)
    rule(context, from: CGPoint(x: 60, y: 416), to: CGPoint(x: 740, y: 416), color: "CCD0D5")
    rule(context, from: CGPoint(x: 860, y: 416), to: CGPoint(x: 1540, y: 416), color: Ink.border)
    drawText(context, "APP ICON / LIGHT", at: CGPoint(x: 60, y: 448), size: 12, font: "HelveticaNeue-Medium", color: "747C88", tracking: 1.1)
    drawText(context, "APP ICON / DARK", at: CGPoint(x: 860, y: 448), size: 12, font: "HelveticaNeue-Medium", color: Ink.secondary, tracking: 1.1)
    context.setFillColor(cgColor(Ink.raised))
    context.fill(CGRect(x: 860, y: 485, width: 680, height: 192))
    for offset in [CGFloat(0), CGFloat(800)] {
        let dark = offset > 0
        for (size, x) in [(128, CGFloat(80)), (64, CGFloat(280)), (32, CGFloat(432)), (16, CGFloat(566))] {
            context.saveGState()
            context.translateBy(x: x + offset, y: 574 - CGFloat(size) / 2)
            context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
            drawIcon(context, background: dark ? Ink.surface : Ink.white, body: dark ? Ink.logoWhite : Ink.logoBlack)
            context.restoreGState()
            drawText(context, "\(size) px", at: CGPoint(x: x + offset, y: 649), size: 11, font: "Menlo-Regular", color: dark ? Ink.secondary : "747C88")
        }
    }
    drawText(context, "88 × 104 / FOUR RECTANGLES", at: CGPoint(x: 60, y: 748), size: 10, font: "HelveticaNeue-Medium", color: "747C88", tracking: 1)
    drawText(context, "FIXED BLUE TOP / ADAPTIVE BODY", at: CGPoint(x: 860, y: 748), size: 10, font: "HelveticaNeue-Medium", color: Ink.secondary, tracking: 1)
}
print(previewURL.path)

let boardURL = rootURL.appendingPathComponent("01-identity-master.png")
try writePNG(to: boardURL, size: CGSize(width: 2048, height: 1400), pixelWidth: 2048, pixelHeight: 1400) { context in
    context.setFillColor(cgColor(Ink.light))
    context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1400))

    drawText(context, "FILMBOX / IDENTITY SYSTEM", at: CGPoint(x: 80, y: 52), size: 16, font: "HelveticaNeue-Medium", tracking: 2.2)
    drawText(context, "光桌", at: CGPoint(x: 78, y: 88), size: 38, font: chineseFont)
    drawText(context, "LIGHT TABLE / V1.1", at: CGPoint(x: 1720, y: 58), size: 14, font: "HelveticaNeue-Medium", tracking: 1.1)
    drawText(context, "2026.10", at: CGPoint(x: 1890, y: 90), size: 14, color: "6A707A", tracking: 1)
    rule(context, from: CGPoint(x: 80, y: 154), to: CGPoint(x: 1968, y: 154))

    section(context, "01 / PRIMARY SIGNATURE", x: 80, y: 190)
    let primaryScale = min(2.35, 1050 / lockupSize.width)
    drawLockup(context, x: 104, y: 289, scale: primaryScale)
    drawText(context, "INK ON LIGHT", at: CGPoint(x: 80, y: 625), size: 12, font: "HelveticaNeue-Medium", color: "6A707A", tracking: 1.5)

    section(context, "02 / BACKGROUND ADAPTATION", x: 1250, y: 190)
    for (x, background, glyph, label) in [
        (CGFloat(1250), Ink.surface, Ink.logoWhite, "ON DARK"),
        (CGFloat(1610), Ink.white, Ink.logoBlack, "ON LIGHT")
    ] {
        context.setFillColor(cgColor(background))
        context.fill(CGRect(x: x, y: 230, width: 334, height: 352))
        drawMark(context, x: x + (334 - 88 * 1.5) / 2, y: 302, scale: 1.5, color: glyph)
        drawText(context, label, at: CGPoint(x: x + 24, y: 548), size: 11, font: "HelveticaNeue-Medium", color: glyph, tracking: 1.7)
    }
    rule(context, from: CGPoint(x: 80, y: 680), to: CGPoint(x: 1968, y: 680))

    section(context, "03 / GEOMETRY", x: 80, y: 715)
    let geometryX: CGFloat = 142
    let geometryY: CGFloat = 800
    let geometryScale: CGFloat = 2
    context.setFillColor(cgColor(Ink.white))
    context.fill(CGRect(x: geometryX, y: geometryY, width: 176, height: 208))
    for x in stride(from: 0, through: 88, by: 4) {
        rule(context, from: CGPoint(x: geometryX + CGFloat(x) * geometryScale, y: geometryY),
             to: CGPoint(x: geometryX + CGFloat(x) * geometryScale, y: geometryY + 208), color: "D7DADF", width: 0.7)
    }
    for y in stride(from: 0, through: 104, by: 4) {
        rule(context, from: CGPoint(x: geometryX, y: geometryY + CGFloat(y) * geometryScale),
             to: CGPoint(x: geometryX + 176, y: geometryY + CGFloat(y) * geometryScale), color: "D7DADF", width: 0.7)
    }
    drawMark(context, x: geometryX, y: geometryY, scale: geometryScale, color: Ink.logoBlack)
    context.setStrokeColor(cgColor(Ink.blue))
    context.setLineWidth(0.8)
    context.stroke(CGRect(x: geometryX, y: geometryY, width: 176, height: 208))
    dimension(context, from: CGPoint(x: geometryX, y: 775), to: CGPoint(x: geometryX + 176, y: 775), label: "88", labelPoint: CGPoint(x: geometryX + 80, y: 754))
    dimension(context, from: CGPoint(x: 116, y: geometryY), to: CGPoint(x: 116, y: geometryY + 208), label: "104", labelPoint: CGPoint(x: 82, y: 896))
    drawText(context, "4-UNIT GRID", at: CGPoint(x: geometryX, y: 1033), size: 12, font: "HelveticaNeue-Medium", color: "6A707A", tracking: 0.8)

    drawText(context, "88 × 104", at: CGPoint(x: 365, y: 783), size: 29, font: "HelveticaNeue-Bold")
    let tableX: [CGFloat] = [365, 407, 450, 493, 536]
    for (index, label) in ["x", "y", "w", "h"].enumerated() {
        drawText(context, label, at: CGPoint(x: tableX[index + 1], y: 836), size: 13, font: "Menlo-Regular", color: "6A707A")
    }
    let coordinates = [["L", "00", "16", "24", "72"], ["C1", "32", "00", "24", "44"], ["C2", "32", "60", "24", "44"], ["R", "64", "16", "24", "72"]]
    for (index, row) in coordinates.enumerated() {
        for (column, value) in row.enumerated() {
            drawText(context, value, at: CGPoint(x: tableX[column], y: 869 + CGFloat(index) * 28), size: 13, font: "Menlo-Regular")
        }
    }
    drawText(context, "BAR 24 / GAP 8 / BREAK 16", at: CGPoint(x: 365, y: 1033), size: 11, font: "HelveticaNeue-Medium", color: "6A707A", tracking: 0.3)

    section(context, "04 / CLEAR SPACE", x: 820, y: 715)
    let clearScale: CGFloat = 1.5
    let clearX: CGFloat = 860
    let clearY: CGFloat = 793
    let clearWidth: CGFloat = (88 + 48) * clearScale
    let clearHeight: CGFloat = (104 + 48) * clearScale
    context.setFillColor(cgColor(Ink.blue, alpha: 0.055))
    context.fill(CGRect(x: clearX, y: clearY, width: clearWidth, height: clearHeight))
    context.saveGState()
    context.setLineDash(phase: 0, lengths: [4, 4])
    context.setStrokeColor(cgColor(Ink.blue, alpha: 0.55))
    context.setLineWidth(1)
    context.stroke(CGRect(x: clearX, y: clearY, width: clearWidth, height: clearHeight))
    context.restoreGState()
    drawMark(context, x: clearX + 36, y: clearY + 36, scale: clearScale, color: Ink.logoBlack)
    dimension(context, from: CGPoint(x: clearX, y: clearY - 16), to: CGPoint(x: clearX + 36, y: clearY - 16), label: "24", labelPoint: CGPoint(x: clearX + 10, y: clearY - 36))
    dimension(context, from: CGPoint(x: clearX + clearWidth + 16, y: clearY), to: CGPoint(x: clearX + clearWidth + 16, y: clearY + 36), label: "24", labelPoint: CGPoint(x: clearX + clearWidth + 27, y: clearY + 12))
    drawText(context, "x = 24 UNITS", at: CGPoint(x: 860, y: 1044), size: 12, font: "HelveticaNeue-Medium", color: "6A707A", tracking: 0.8)

    section(context, "05 / COLOUR TOKENS", x: 1300, y: 715)
    let tokens = [
        ("BRAND", Ink.blue), ("LOGO BLACK", Ink.logoBlack), ("LOGO WHITE", Ink.logoWhite), ("SURFACE", Ink.surface), ("RAISED", Ink.raised),
        ("BORDER", Ink.border), ("TEXT", Ink.white), ("SECONDARY", Ink.secondary), ("CANVAS", Ink.canvas), ("LIGHT", Ink.light)
    ]
    for (index, token) in tokens.enumerated() {
        let x = 1300 + CGFloat(index % 5) * 130
        let y = 778 + CGFloat(index / 5) * 138
        let rect = CGRect(x: x, y: y, width: 116, height: 58)
        context.setFillColor(cgColor(token.1))
        context.fill(rect)
        if token.1 == Ink.white || token.1 == Ink.light || token.1 == Ink.logoWhite {
            context.setLineWidth(0.7)
            context.setStrokeColor(cgColor("CFD2D6"))
            context.stroke(rect)
        }
        drawText(context, token.0, at: CGPoint(x: x, y: y + 70), size: 11, font: "HelveticaNeue-Medium", color: "626A75", tracking: 0.7)
        drawText(context, "#\(token.1)", at: CGPoint(x: x, y: y + 91), size: 14, font: "Menlo-Regular")
    }
    rule(context, from: CGPoint(x: 80, y: 1100), to: CGPoint(x: 1968, y: 1100))

    section(context, "06 / WORDMARK", x: 80, y: 1135)
    let boardEnglish = outline("filmbox", fontName: englishFont, size: 76, tracking: -1.14)
    context.setFillColor(cgColor(Ink.logoBlack))
    let boardEnglishPlaced = CGMutablePath()
    boardEnglishPlaced.addPath(boardEnglish.path, transform: CGAffineTransform(translationX: 80, y: 1186))
    context.addPath(boardEnglishPlaced)
    context.fillPath()
    drawText(context, "HelveticaNeue-Bold", at: CGPoint(x: 80, y: 1280), size: 15, font: "HelveticaNeue-Medium")
    drawText(context, "Tracking −0.015 em / outlined", at: CGPoint(x: 80, y: 1307), size: 12, color: "6A707A")
    drawText(context, "菲林盒", at: CGPoint(x: 650, y: 1186), size: 51, font: chineseFont, tracking: 5.1)
    drawText(context, "PingFangSC-Medium", at: CGPoint(x: 650, y: 1280), size: 15, font: "HelveticaNeue-Medium")
    drawText(context, "Tracking +0.10 em / outlined", at: CGPoint(x: 650, y: 1307), size: 12, color: "6A707A")

    section(context, "07 / APP ICON · 1×", x: 1250, y: 1135)
    for (size, x) in [(128, CGFloat(1250)), (64, CGFloat(1455)), (32, CGFloat(1620)), (16, CGFloat(1775))] {
        let y = 1236 - CGFloat(size) / 2
        context.saveGState()
        context.translateBy(x: x, y: y)
        context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        drawIcon(context)
        context.restoreGState()
        drawText(context, "\(size) px", at: CGPoint(x: x, y: 1320), size: 12, font: "Menlo-Regular", color: "6A707A")
    }
    rule(context, from: CGPoint(x: 80, y: 1351), to: CGPoint(x: 1968, y: 1351))
    drawText(context, "88 × 104 / 4 RECTANGLES / CLEAR SPACE 24", at: CGPoint(x: 80, y: 1371), size: 10, font: "HelveticaNeue-Medium", color: "6A707A", tracking: 1)
    drawText(context, "FILMBOX · LIGHT TABLE · 01", at: CGPoint(x: 1740, y: 1371), size: 10, font: "HelveticaNeue-Medium", color: "6A707A", tracking: 0.8)
}

let specification: [String: Any] = [
    "name": "Filmbox · 菲林盒 / 光桌",
    "version": "1.1",
    "coordinateSystem": "top-left origin; all values in logical units",
    "mark": ["viewBox": [0, 0, 88, 104], "grid": 4, "clearSpace": 24,
             "rectangles": markRects.map { [Int($0.minX), Int($0.minY), Int($0.width), Int($0.height)] },
             "fixedBlueRectangleIndex": 1, "fixedBlue": "#\(Ink.blue)", "bodyOnLight": "#\(Ink.logoBlack)", "bodyOnDark": "#\(Ink.logoWhite)"],
    "lockup": ["markToWordmarkGap": 32, "wordmarkFont": englishFont, "wordmarkFontSize": 100,
               "wordmarkTracking": -1.5, "chineseFont": chineseFont, "chineseFontSize": 22,
               "chineseTracking": 2.2, "width": Double(lockupSize.width), "height": 104,
               "englishInkY": Double(englishY), "chineseInkY": Double(chineseY)],
    "colours": ["brandBlue": "#\(Ink.blue)", "logoBlack": "#\(Ink.logoBlack)", "logoWhite": "#\(Ink.logoWhite)", "surface": "#\(Ink.surface)", "surfaceRaised": "#\(Ink.raised)",
                "border": "#\(Ink.border)", "text": "#\(Ink.white)", "secondary": "#\(Ink.secondary)",
                "canvas": "#\(Ink.canvas)", "lightCanvas": "#\(Ink.light)"],
    "appIcon": ["canvas": 1024, "container": [64, 64, 896, 896], "cornerRadius": 208,
                "glyphScale": 5, "glyphOrigin": [Double(iconMarkX), Double(iconMarkY)],
                "containerOnLight": "#\(Ink.white)", "containerOnDark": "#\(Ink.surface)", "blueContainer": false,
                "transparentVariants": ["light", "dark"],
                "exportSizes": [16, 32, 64, 128, 256, 512, 1024]],
    "output": ["colourSpace": "sRGB", "transparentLogoPNG": true, "svgTextIsOutlined": true, "boardPixels": [2048, 1400], "previewPixels": [1600, 800]]
]
let json = try JSONSerialization.data(withJSONObject: specification, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try json.write(to: rootURL.appendingPathComponent("identity-spec.json"), options: .atomic)
print("Wordmark ink bounds: \(decimal(wordmark.width)) × \(decimal(wordmark.height))")
print("Chinese ink bounds: \(decimal(chinese.width)) × \(decimal(chinese.height))")
print("Lockup: \(decimal(lockupSize.width)) × \(decimal(lockupSize.height))")
print(boardURL.path)
