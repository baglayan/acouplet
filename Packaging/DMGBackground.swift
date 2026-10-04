import AppKit

let arguments = CommandLine.arguments
if !(3...4).contains(arguments.count) || (arguments.count == 4 && !["dark", "pearl"].contains(arguments[3])) {
    fputs("Expected app icon and output TIFF paths, optionally followed by dark or pearl.\n", stderr)
    exit(2)
}
let pearl = arguments.count == 4 && arguments[3] == "pearl"
guard let icon = NSImage(contentsOfFile: arguments[1]),
      let iconImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Could not read the app icon.\n", stderr)
    exit(1)
}
let iconBitmap = NSBitmapImageRep(cgImage: iconImage)
let colors = stride(from: 0.18, through: 0.82, by: 0.08).map { position in
    iconBitmap.colorAt(x: Int(Double(iconBitmap.pixelsWide) * 0.20),
                       y: Int(Double(iconBitmap.pixelsHigh) * position))!.usingColorSpace(.sRGB)!
}
let width = 680
let height = 410
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let backgroundColors = pearl ? [
    NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 249 / 255, alpha: 1).cgColor,
    NSColor(srgbRed: 242 / 255, green: 242 / 255, blue: 241 / 255, alpha: 1).cgColor,
    NSColor(srgbRed: 230 / 255, green: 230 / 255, blue: 229 / 255, alpha: 1).cgColor
] : [
    NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1).cgColor,
    NSColor(srgbRed: 0.075, green: 0.075, blue: 0.085, alpha: 1).cgColor
]
let background = CGGradient(colorsSpace: colorSpace, colors: backgroundColors as CFArray, locations: nil)!
context.drawLinearGradient(background, start: CGPoint(x: 340, y: 410),
                           end: CGPoint(x: 340, y: 0), options: [])
if !pearl {
    context.setFillColor(NSColor(srgbRed: 0.66, green: 0.66, blue: 0.68, alpha: 1).cgColor)
    for x in [114.0, 454.0] {
        context.addPath(CGPath(roundedRect: CGRect(x: x, y: 179, width: 112, height: 24),
                              cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
    }
}
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: 285, y: 215))
arrow.addCurve(to: CGPoint(x: 395, y: 215), control1: CGPoint(x: 310, y: 195), control2: CGPoint(x: 370, y: 195))
arrow.move(to: CGPoint(x: 381, y: 213))
arrow.addLine(to: CGPoint(x: 395, y: 215))
arrow.addLine(to: CGPoint(x: 390, y: 202))
let frame = CGPath(roundedRect: CGRect(x: 432, y: 166, width: 156, height: 168),
                   cornerWidth: 24, cornerHeight: 24, transform: nil)
let dashedFrame = frame.copy(dashingWithPhase: 0, lengths: [6, 7])
context.addPath(arrow.copy(strokingWithWidth: 3.5, lineCap: .round, lineJoin: .round, miterLimit: 0))
context.addPath(dashedFrame.copy(strokingWithWidth: 1.5, lineCap: .round, lineJoin: .round, miterLimit: 0))
context.clip()
let gradient = CGGradient(colorsSpace: colorSpace, colors: colors.map(\.cgColor) as CFArray,
                          locations: nil)!
context.drawLinearGradient(gradient, start: CGPoint(x: 340, y: 334),
                           end: CGPoint(x: 340, y: 166), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue]) else {
    fputs("Could not encode the DMG background.\n", stderr)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: arguments[2]))
