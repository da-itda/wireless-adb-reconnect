// Windows용 .ico 생성: swift assets/make_ico.swift assets/icon.png assets/adb-revive.ico
// 작은 크기(16~64)는 32비트 BMP(DIB), 256은 PNG — 구형 API(.NET Framework System.Drawing)까지 호환
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!

func render(_ size: Int) -> [UInt8] {   // 비-프리멀티플 BGRA, 위→아래
    var px = [UInt8](repeating: 0, count: size * size * 4)
    let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 && px[i + 3] < 255 {
        let a = Double(px[i + 3])
        for c in 0..<3 { px[i + c] = UInt8(min(255, (Double(px[i + c]) * 255 / a).rounded())) }
    }
    return px
}

func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }

func dib(_ size: Int) -> [UInt8] {
    let px = render(size)
    var out = le32(40) + le32(size) + le32(size * 2) + le16(1) + le16(32) + le32(0) + le32(0) + le32(0) + le32(0) + le32(0) + le32(0)
    for y in (0..<size).reversed() { out += px[(y * size * 4)..<((y + 1) * size * 4)] }   // 아래→위
    let maskRow = ((size + 31) / 32) * 4
    out += [UInt8](repeating: 0, count: maskRow * size)                                    // AND 마스크(알파 사용)
    return out
}

func png(_ size: Int) -> [UInt8] {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return [UInt8](data as Data)
}

let sizes = [16, 20, 24, 32, 40, 48, 64, 256]
let blobs = sizes.map { $0 == 256 ? png($0) : dib($0) }
var out = le16(0) + le16(1) + le16(sizes.count)
var offset = 6 + 16 * sizes.count
for (s, b) in zip(sizes, blobs) {
    out += [UInt8(s % 256), UInt8(s % 256), 0, 0] + le16(1) + le16(32) + le32(b.count) + le32(offset)
    offset += b.count
}
for b in blobs { out += b }
try! Data(out).write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) (\(sizes))")
