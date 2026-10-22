// 심볼 PNG(몸체 = 검정, 전파 = 색)를 정사각형으로 맞추고 몸체·전파를 각각 다른 색으로 칠한다.
//   swift assets/tint_symbol.swift <심볼.png> <출력.png> <몸체색|none> <전파색|none> [크기]
//   예) 몸체 마스크: ... status-body.png FFFFFF none 72   (none = 그 부분을 지움)
// 전파는 무채색이 아닌(밝은) 픽셀, 몸체는 검정 픽셀로 구분한다 (둘은 떨어져 있어 가장자리도 섞이지 않음)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
let src = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!, 0, nil)!
func rgb(_ s: String) -> (UInt8, UInt8, UInt8)? {
    guard s != "none", let v = UInt32(s, radix: 16) else { return nil }
    return (UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
}
let body = rgb(a[3]), waves = rgb(a[4])

// 원본을 정사각형(긴 변 기준) 가운데에 놓는다
let side = max(src.width, src.height)
var px = [UInt8](repeating: 0, count: side * side * 4)
let cs = CGColorSpaceCreateDeviceRGB()
let info = CGImageAlphaInfo.premultipliedLast.rawValue
let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: cs, bitmapInfo: info)!
ctx.draw(src, in: CGRect(x: (side - src.width) / 2, y: (side - src.height) / 2, width: src.width, height: src.height))

for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 {
    let al = Double(px[i + 3])
    let bright = Double(max(px[i], px[i + 1], px[i + 2])) * 255 / al > 40
    if let c = bright ? waves : body {
        px[i] = UInt8((Double(c.0) * al / 255).rounded())
        px[i + 1] = UInt8((Double(c.1) * al / 255).rounded())
        px[i + 2] = UInt8((Double(c.2) * al / 255).rounded())
    } else {
        px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
    }
}
var img = ctx.makeImage()!

if a.count > 5, let size = Int(a[5]) {
    let small = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info)!
    small.interpolationQuality = .high
    small.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    img = small.makeImage()!
}
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, img, nil)
CGImageDestinationFinalize(d)
