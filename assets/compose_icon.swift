// 사용자 심볼(PNG)을 macOS 아이콘 그리드의 흰 둥근 사각형 위에 올린다: swift compose_icon.swift <심볼.png> <출력.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
let a = CommandLine.arguments
let sym = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!, 0, nil)!
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
ctx.addPath(path); ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(path); ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08)); ctx.setLineWidth(2); ctx.strokePath()
// 심볼은 사각형 안쪽 약 62% 폭, 가운데
let w = 824.0 * 0.62, h = w * Double(sym.height) / Double(sym.width)
ctx.interpolationQuality = .high
ctx.draw(sym, in: CGRect(x: 512 - w / 2, y: 512 - h / 2, width: w, height: h))
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
