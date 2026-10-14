// Ideal Video Encoder - builds the app icons from one square source image
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// macOS: an .iconset (16-1024 px) with the artwork in a rounded square on Apple's icon grid (824 of 1024 px).
// Windows: an .ico with PNG frames at 16, 24, 32, 48, 64, 128 and 256 px, as a rounded square with a small margin.
// At 32 px and below the detailed artwork turns to noise, so those sizes use a tighter crop around the
// centre of interest (the play symbol).
//
// Usage: swift make-icon.swift <source image> <out .iconset folder> <out .ico>

import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count == 4 else { print("usage: make-icon <source image> <out.iconset> <out.ico>"); exit(64) }
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("cannot read \(args[1])"); exit(1) }
let iconset = URL(fileURLWithPath: args[2])
let icoURL = URL(fileURLWithPath: args[3])
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

let W = CGFloat(image.width), H = CGFloat(image.height)
/// Square region of the source to use: the whole image, or the close crop for small sizes.
func sourceRect(close: Bool) -> CGRect {
    let side = min(W, H)
    guard close else { return CGRect(x: (W - side) / 2, y: (H - side) / 2, width: side, height: side) }
    // Centre of interest: the housing with the play symbol, slightly right of and above the middle
    let c = 0.46 * side, cx = 0.535 * W, cy = 0.49 * H
    return CGRect(x: max(0, min(W - c, cx - c / 2)), y: max(0, min(H - c, cy - c / 2)), width: c, height: c)
}

/// Renders a rounded-square icon of `px` pixels: artwork inside `margin`, corners `radius` (fractions of px).
func render(_ px: Int, margin: CGFloat, radius: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let s = CGFloat(px)
    let box = CGRect(x: s * margin, y: s * margin, width: s * (1 - 2 * margin), height: s * (1 - 2 * margin))
    let path = CGPath(roundedRect: box, cornerWidth: box.width * radius, cornerHeight: box.width * radius, transform: nil)
    ctx.addPath(path); ctx.clip()
    let crop = image.cropping(to: sourceRect(close: px <= 32))!
    ctx.draw(crop, in: box)
    // A hairline edge keeps the dark artwork distinct on dark backgrounds
    ctx.resetClip()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.setLineWidth(max(1, s / 256))
    ctx.strokePath()
    return ctx.makeImage()!
}

func png(_ img: CGImage) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

// macOS iconset: Apple's grid puts 824 px of artwork in a 1024 px canvas, corner radius about 22.4%
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png(render(base * scale, margin: 100.0 / 1024, radius: 0.224)).write(to: iconset.appendingPathComponent(name))
    }
}

// Windows .ico: PNG frames (supported since Vista), rounded square with a small margin
let sizes = [16, 24, 32, 48, 64, 128, 256]
let frames = sizes.map { png(render($0, margin: 0.03, radius: 0.18)) }
var ico = Data()
func u16(_ v: Int) { ico.append(UInt8(v & 0xff)); ico.append(UInt8(v >> 8 & 0xff)) }
func u32(_ v: Int) { for i in 0..<4 { ico.append(UInt8(v >> (8 * i) & 0xff)) } }
u16(0); u16(1); u16(sizes.count)
var offset = 6 + 16 * sizes.count
for (s, f) in zip(sizes, frames) {
    ico.append(UInt8(s == 256 ? 0 : s)); ico.append(UInt8(s == 256 ? 0 : s)); ico.append(0); ico.append(0)
    u16(1); u16(32); u32(f.count); u32(offset)
    offset += f.count
}
for f in frames { ico.append(f) }
try ico.write(to: icoURL)
print("wrote \(iconset.path) and \(icoURL.path) (\(ico.count) bytes, \(sizes.map(String.init).joined(separator: ", ")) px)")
