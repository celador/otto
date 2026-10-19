// Otto icon + mark generator (CoreGraphics, no paid image APIs).
// The mark: a bold rounded letter-O ring with a small dot offset up-right inside it
// (an agent "eye" / signal). Monochrome on purpose.
//
// Usage (from the repo root): swift scripts/make_otto_icon.swift
// Writes:
//   ios/Hermes/Assets.xcassets/OttoAppIcon.appiconset/icon-{default,dark,tinted}.png  (1024, opaque)
//   ios/HermesWatch/Assets.xcassets/AppIcon.appiconset/icon.png                   (1024, opaque)
//   ios/{Hermes,HermesWidgets}/Assets.xcassets/OttoMark.imageset/otto-mark.pdf    (vector, template)
//   ios/HermesTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets/...       (layers + top shelf)
//   assets/logo/otto-icon-{default,light,tinted}.png, assets/logo/otto-mark.pdf
import AppKit
import CoreGraphics

let cs = CGColorSpaceCreateDeviceRGB()
let nearBlack = CGColor(red: 0.067, green: 0.067, blue: 0.075, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

/// Draws the mark centred at (cx, cy) with overall diameter `d` (outer edge of the ring).
func drawMark(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, d: CGFloat, color: CGColor) {
    let u = d / 0.60                  // geometry designed for d = 0.60 of a unit square
    let lineW = 0.115 * u
    let r = 0.30 * u - lineW / 2      // ring centre-line radius
    ctx.setStrokeColor(color)
    ctx.setLineWidth(lineW)
    ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    ctx.strokePath()
    // Offset dot, up and to the right (CoreGraphics y points up).
    let dr = 0.062 * u, off = 0.072 * u
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: cx + off - dr, y: cy + off - dr, width: 2 * dr, height: 2 * dr))
}

func bitmap(_ w: Int, _ h: Int, opaque: Bool) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
              bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func save(_ ctx: CGContext, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(path)")
}

func icon(bg: CGColor, fg: CGColor, _ path: String) {
    let s: CGFloat = 1024
    let ctx = bitmap(1024, 1024, opaque: true)
    ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    drawMark(ctx, cx: s / 2, cy: s / 2, d: s * 0.60, color: fg)
    save(ctx, path)
}

func pdfMark(_ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 100, height: 100)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    drawMark(ctx, cx: 50, cy: 50, d: 100, color: black)
    ctx.endPDFPage(); ctx.closePDF()
    print("wrote \(path)")
}

let app = "ios/Hermes/Assets.xcassets/OttoAppIcon.appiconset"
icon(bg: nearBlack, fg: white, "\(app)/icon-default.png")
icon(bg: nearBlack, fg: white, "\(app)/icon-dark.png")
icon(bg: black, fg: CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1), "\(app)/icon-tinted.png")
icon(bg: nearBlack, fg: white, "ios/HermesWatch/Assets.xcassets/AppIcon.appiconset/icon.png")
icon(bg: nearBlack, fg: white, "assets/logo/otto-icon-default.png")
icon(bg: white, fg: black, "assets/logo/otto-icon-light.png")
icon(bg: black, fg: CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1), "assets/logo/otto-icon-tinted.png")
for dir in ["ios/Hermes", "ios/HermesWidgets"] {
    pdfMark("\(dir)/Assets.xcassets/OttoMark.imageset/otto-mark.pdf")
}
pdfMark("assets/logo/otto-mark.pdf")

// tvOS layered icon + top shelf.
let tv = "ios/HermesTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
for (stack, sizes) in [("App Icon.imagestack", [(400, 240), (800, 480)]), ("App Icon - App Store.imagestack", [(1280, 768)])] {
    for (w, h) in sizes {
        let back = bitmap(w, h, opaque: true)
        back.setFillColor(nearBlack); back.fill(CGRect(x: 0, y: 0, width: w, height: h))
        save(back, "\(tv)/\(stack)/Back.imagestacklayer/Content.imageset/back-\(w)x\(h).png")
        let front = bitmap(w, h, opaque: false)
        drawMark(front, cx: CGFloat(w) / 2, cy: CGFloat(h) / 2, d: CGFloat(h) * 0.62, color: white)
        save(front, "\(tv)/\(stack)/Front.imagestacklayer/Content.imageset/front-\(w)x\(h).png")
    }
}
for (set, w, h) in [("Top Shelf Image.imageset", 1920, 720), ("Top Shelf Image.imageset", 3840, 1440),
                    ("Top Shelf Image Wide.imageset", 2320, 720), ("Top Shelf Image Wide.imageset", 4640, 1440)] {
    let c = bitmap(w, h, opaque: true)
    c.setFillColor(nearBlack); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    drawMark(c, cx: CGFloat(w) / 2, cy: CGFloat(h) / 2, d: CGFloat(h) * 0.45, color: white)
    save(c, "\(tv)/\(set)/shelf-\(w)x\(h).png")
}
