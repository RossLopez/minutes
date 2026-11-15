// SPDX-License-Identifier: GPL-3.0-or-later

// Draws the DMG window's background at 1x and 2x: a soft gradient in the icon's blues, an arrow
// from the app to Applications, and a line of text. Usage, from the repo root:
//   swift scripts/render-dmg-background.swift packaging/dmg

import AppKit
import CoreGraphics

let size = CGSize(width: 660, height: 400)
let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "packaging/dmg", isDirectory: true)

func render(scale: CGFloat) -> Data {
    let width = Int(size.width * scale)
    let height = Int(size.height * scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: scale, y: scale)

    // Background: near-white to a pale blue, top to bottom.
    let colors = [CGColor(srgbRed: 0.98, green: 0.98, blue: 1.0, alpha: 1),
                  CGColor(srgbRed: 0.90, green: 0.92, blue: 0.99, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])

    // Arrow between the icons, which dmgbuild places at x 180 and 480, y 170 from the top.
    let blue = CGColor(srgbRed: 0.23, green: 0.31, blue: 0.85, alpha: 0.55)
    let midY = size.height - 170
    context.setStrokeColor(blue)
    context.setLineWidth(6)
    context.setLineCap(.butt)
    context.move(to: CGPoint(x: 280, y: midY))
    context.addLine(to: CGPoint(x: 362, y: midY))
    context.strokePath()
    context.setFillColor(blue)
    context.move(to: CGPoint(x: 392, y: midY))
    context.addLine(to: CGPoint(x: 366, y: midY + 17))
    context.addLine(to: CGPoint(x: 366, y: midY - 17))
    context.closePath()
    context.fillPath()

    // The instruction, centered near the bottom.
    let text = NSAttributedString(string: "Drag Minutes to Applications to install it", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.25, green: 0.27, blue: 0.35, alpha: 1),
    ])
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    context.textPosition = CGPoint(x: (size.width - bounds.width) / 2, y: 92)
    CTLineDraw(line, context)

    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = size
    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: folder.appendingPathComponent("background.png"))
try render(scale: 2).write(to: folder.appendingPathComponent("background@2x.png"))
print("Wrote background.png and background@2x.png in \(folder.path)")
