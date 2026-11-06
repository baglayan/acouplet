import Foundation
import CoreGraphics
import ImageIO

struct Bounds: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

func gap(_ occupied: [Bool]) -> Range<Int>? {
    guard let start = occupied.firstIndex(of: true), let end = occupied.lastIndex(of: true) else { return nil }
    var best: Range<Int>?
    var index = start
    while index < end {
        if occupied[index] { index += 1; continue }
        let lower = index
        while index < end && !occupied[index] { index += 1 }
        if index - lower > (best?.count ?? 0) { best = lower..<index }
    }
    return best
}

let paths = try JSONDecoder().decode([String].self, from: FileHandle.standardInput.readDataToEndOfFile())
let split = CommandLine.arguments.contains("--split")
var result: [String: Bounds] = [:]
var parts: [String: [Bounds]] = [:]
for path in paths {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path])
    }
    let width = image.width
    let height = image.height
    let stride = width * 4
    let name = url.deletingPathExtension().lastPathComponent
    var pixels = [UInt8](repeating: 0, count: stride * height)
    pixels.withUnsafeMutableBytes { bytes in
        let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: stride,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = bytes.bindMemory(to: UInt8.self)
        func bounds(_ columns: Range<Int>, _ rows: Range<Int>) -> Bounds {
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in rows {
                for x in columns where data[y * stride + x * 4 + 3] > 0 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
            precondition(maxX >= minX && maxY >= minY, "Artwork has no visible pixels: \(path)")
            return Bounds(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                          width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height))
        }
        result[name] = bounds(0..<width, 0..<height)
        if split {
            var columns = [Bool](repeating: false, count: width)
            var rows = [Bool](repeating: false, count: height)
            for y in 0..<height {
                for x in 0..<width where data[y * stride + x * 4 + 3] > 0 {
                    columns[x] = true
                    rows[y] = true
                }
            }
            if let gap = gap(columns) {
                parts[name] = [bounds(0..<gap.lowerBound, 0..<height), bounds(gap.upperBound..<width, 0..<height)]
            } else if let gap = gap(rows) {
                parts[name] = [bounds(0..<width, 0..<gap.lowerBound), bounds(0..<width, gap.upperBound..<height)]
                    .sorted { $0.x + $0.width / 2 < $1.x + $1.width / 2 }
            } else {
                parts[name] = []
            }
        }
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try split ? encoder.encode(parts) : encoder.encode(result))
