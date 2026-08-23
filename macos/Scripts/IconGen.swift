import AppKit

// Renders a macOS-proportioned iconset from a full-bleed source image.
//
// The shared logo set is drawn edge to edge, the way Windows .ico files are.
// macOS instead expects the artwork inset on a transparent canvas - Apple's
// grid puts an 824pt body in a 1024pt tile - so an unpadded icon renders
// noticeably larger than every neighbour in the Dock.

let scale = 824.0 / 1024.0     // Apple's macOS icon grid
let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: IconGen <source.png> <out.iconset>\n".utf8))
    exit(2)
}
guard let source = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8))
    exit(1)
}

let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// One iconset entry: the tile size in pixels and its filename.
let entries: [(px: Int, name: String)] = [
    (16, "icon_16x16.png"),     (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),     (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),  (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),  (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),  (1024, "icon_512x512@2x.png"),
]

for entry in entries {
    let side = CGFloat(entry.px)
    let body = (side * scale).rounded()
    let inset = ((side - body) / 2).rounded()

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: entry.px, pixelsHigh: entry.px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { continue }
    rep.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: NSRect(x: inset, y: inset, width: body, height: body),
                from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: outDir.appendingPathComponent(entry.name))
}
print("wrote \(entries.count) tiles to \(outDir.lastPathComponent)")
