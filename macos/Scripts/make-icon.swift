// Ideal Video Encoder for macOS - builds AppIcon.iconset from assets/app.ico
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Windows icon is simple vector geometry (a rounded square with a play triangle, the XAML AppIcon:
// Rect 0,0,32,32 radius 7, triangle 12.5,9.5 -> 23,16 -> 12.5,22.5) stored as PNGs up to 256 px.
// macOS needs up to 1024 px, so this redraws the same geometry at every size, in the colour read from the
// .ico's 256 px image, and reports how closely its 256 px rendering matches that image.
//
// Usage: swift make-icon.swift <app.ico> <output .iconset folder> [macos-grid]
//   macos-grid: inset the artwork to Apple's icon grid (824 of 1024 px) so it sits like other Mac icons.

import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: make-icon <app.ico> <out.iconset> [macos-grid]"); exit(64) }
let ico = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let outDir = URL(fileURLWithPath: args[2])
let macGrid = args.count > 3 && args[3] == "macos-grid"

// Largest PNG inside the .ico
func icoImages(_ d: Data) -> [(Int, Data)] {
    let n = Int(d[4]) | Int(d[5]) << 8
    return (0..<n).map { i in
        let e = 6 + 16 * i
        let w = d[e] == 0 ? 256 : Int(d[e])
        let size = d[e + 8..<e + 12].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let off = d[e + 12..<e + 16].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        return (w, d.subdata(in: off..<off + size))
    }
}
guard let (refSize, refPNG) = icoImages(ico).max(by: { $0.0 < $1.0 }),
      let src = CGImageSourceCreateWithData(refPNG as CFData, nil),
      let refImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("no PNG in .ico"); exit(1) }

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
/// Raw RGBA bytes (premultiplied) of an image drawn into an sRGB context, no colour matching beyond tagging.
func bytes(_ img: CGImage, _ px: Int) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: px * px * 4)
    let ctx = CGContext(data: &buf, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4, space: img.colorSpace ?? srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: px, height: px))
    return buf
}
let ref = bytes(refImage, refSize)
// Colour of the square, just inside the left edge at mid-height (row order is bottom-up here, symmetric anyway)
let at = (refSize / 2 * refSize + refSize / 10) * 4
let (fr, fg, fb) = (ref[at], ref[at + 1], ref[at + 2])
print(String(format: "ico %dpx, fill #%02X%02X%02X", refSize, fr, fg, fb))

func render(_ px: Int, inset: Bool) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    let s = CGFloat(px)
    let margin = inset ? s * 100 / 1024 : 0           // Apple grid: 824 px artwork in a 1024 px canvas
    let box = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let u = box.width / 32                              // XAML units
    ctx.setFillColor(CGColor(srgbRed: CGFloat(fr) / 255, green: CGFloat(fg) / 255, blue: CGFloat(fb) / 255, alpha: 1))
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: 7 * u, cornerHeight: 7 * u, transform: nil))
    ctx.fillPath()
    // XAML y grows downwards; Core Graphics upwards
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * u, y: box.maxY - y * u) }
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.move(to: p(12.5, 9.5)); ctx.addLine(to: p(23, 16)); ctx.addLine(to: p(12.5, 22.5)); ctx.closePath()
    ctx.fillPath()
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// Fidelity: our full-bleed rendering vs the .ico's own largest image, byte for byte
let mine = bytes(render(refSize, inset: false), refSize)
var sum = 0.0, maxD = 0, over8 = 0
for i in 0..<mine.count { let d = abs(Int(mine[i]) - Int(ref[i])); sum += Double(d); maxD = max(maxD, d); if d > 8 { over8 += 1 } }
print(String(format: "redraw vs ico at %dpx: mean abs difference %.2f/255, %.2f%% of samples differ by more than 8 (edges), max %d",
             refSize, sum / Double(mine.count), Double(over8) / Double(mine.count) * 100, maxD))

try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        writePNG(render(base * scale, inset: macGrid), outDir.appendingPathComponent(name))
    }
}
print("wrote \(outDir.path)")
