#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO

let rootURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    .deletingLastPathComponent().deletingLastPathComponent()
let assetsURL = rootURL.appendingPathComponent("assets", isDirectory: true)

final class SVGReader: NSObject, XMLParserDelegate {
    var rectangles: [[String: String]] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "rect" { rectangles.append(attributes) }
    }
}

func readSVG(_ name: String) throws -> [[String: String]] {
    let url = assetsURL.appendingPathComponent(name)
    let text = try String(contentsOf: url, encoding: .utf8)
    precondition(!text.contains("<text") && !text.contains("<image") && !text.contains("href=") && !text.contains("font-family"), "SVG contains a non-outline dependency: \(name)")
    let reader = SVGReader()
    guard let parser = XMLParser(contentsOf: url) else { fatalError("Cannot read SVG") }
    parser.delegate = reader
    precondition(parser.parse(), "Malformed SVG: \(name)")
    return reader.rectangles
}

let expectedGeometry = [["0", "16", "24", "72"], ["32", "0", "24", "44"], ["32", "60", "24", "44"], ["64", "16", "24", "72"]]
for (name, body) in [("logo-mark-light.svg", "#000000"), ("logo-mark-dark.svg", "#FFFFFF"), ("logo-mark-adaptive.svg", "currentColor")] {
    let rects = try readSVG(name)
    precondition(rects.count == 4)
    for (index, rect) in rects.enumerated() {
        precondition([rect["x"], rect["y"], rect["width"], rect["height"]] == expectedGeometry[index].map(Optional.some))
        precondition(rect["fill"] == (index == 1 ? "#315BFF" : body))
    }
}
for name in ["logo-lockup-light.svg", "logo-lockup-dark.svg", "logo-wordmark-black.svg", "logo-wordmark-white.svg", "app-icon.svg", "app-icon-dark.svg", "app-icon-transparent-light.svg", "app-icon-transparent-dark.svg"] {
    _ = try readSVG(name)
}

func image(_ name: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(assetsURL.appendingPathComponent(name) as CFURL, nil),
          let result = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Invalid PNG: \(name)") }
    return result
}

func rgba(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    guard let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { fatalError("Invalid sample") }
    var bytes = [UInt8](repeating: 0, count: 4)
    bytes.withUnsafeMutableBytes { buffer in
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Invalid sample context") }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return bytes
}

for (name, body) in [("logo-mark-light.png", UInt8(0)), ("logo-mark-dark.png", UInt8(255))] {
    let mark = image(name)
    precondition(mark.width == 1408 && mark.height == 1664)
    precondition(rgba(mark, x: 704, y: 352) == [49, 91, 255, 255])
    precondition(rgba(mark, x: 192, y: 832) == [body, body, body, 255])
    precondition(rgba(mark, x: 704, y: 1312) == [body, body, body, 255])
    precondition(rgba(mark, x: 1216, y: 832) == [body, body, body, 255])
    precondition(rgba(mark, x: 448, y: 832)[3] == 0)
}
for (name, body, background) in [("app-icon", UInt8(0), [UInt8(245), 246, 247, 255]), ("app-icon-dark", UInt8(255), [UInt8(23), 25, 29, 255])] {
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        let filename = size == 1024 ? "\(name).png" : "\(name)-\(size).png"
        let icon = image(filename)
        precondition(icon.width == size && icon.height == size)
        if size == 1024 {
            precondition(rgba(icon, x: 512, y: 350) == [49, 91, 255, 255])
            precondition(rgba(icon, x: 352, y: 450) == [body, body, body, 255])
            precondition(rgba(icon, x: 100, y: 512) == background)
        }
    }
}
for name in ["app-icon-transparent-light.png", "app-icon-transparent-dark.png"] {
    let icon = image(name)
    precondition(icon.width == 1024 && icon.height == 1024)
    precondition(rgba(icon, x: 100, y: 512)[3] == 0)
    precondition(rgba(icon, x: 512, y: 350) == [49, 91, 255, 255])
}
print("V1.1 validated: 4 exact rectangles; fixed blue top; pure black/white bodies; 14 icon sizes; 2 transparent icons; outlined SVGs.")
