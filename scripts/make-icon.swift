// Draws the app icon: a waveform turning into lines of text.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824 pt rounded square centred in 1024 with a soft shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.13, blue: 0.17, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [NSColor(srgbRed: 0.17, green: 0.22, blue: 0.29, alpha: 1).cgColor,
             NSColor(srgbRed: 0.08, green: 0.10, blue: 0.14, alpha: 1).cgColor] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()

func capsule(_ rect: CGRect, _ color: NSColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width < rect.height ? rect.width / 2 : rect.height / 2,
                       cornerHeight: rect.width < rect.height ? rect.width / 2 : rect.height / 2, transform: nil))
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
}

let midY: CGFloat = 512
let barW: CGFloat = 40
let gap: CGFloat = 26
let heights: [CGFloat] = [120, 250, 380, 210, 300]
let warm = NSColor(srgbRed: 1.0, green: 0.74, blue: 0.30, alpha: 1)
var x: CGFloat = 214
for (i, h) in heights.enumerated() {
    capsule(CGRect(x: x, y: midY - h / 2, width: barW, height: h), i == 2 ? warm : .white)
    x += barW + gap
}

// Lines of text on the right, aligned to the waveform's centre.
let lineH: CGFloat = 40
let lineX: CGFloat = x + 34
let lines: [(CGFloat, CGFloat)] = [(midY + 120, 236), (midY + 40, 196), (midY - 40, 236), (midY - 120, 140)]
for (y, w) in lines {
    capsule(CGRect(x: lineX, y: y - lineH / 2, width: w, height: lineH), NSColor.white.withAlphaComponent(0.55))
}

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
