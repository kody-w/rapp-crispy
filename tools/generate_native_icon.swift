import AppKit
import Foundation

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = repository.appendingPathComponent("native/.build/Crispy.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: pixels * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Could not allocate an icon bitmap")
        }
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.setFillColor(CGColor(red: 0.035, green: 0.14, blue: 0.16, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 70, y: 70, width: 884, height: 884),
                              cornerWidth: 190, cornerHeight: 190, transform: nil))
        context.fillPath()
        let heights: [CGFloat] = [160, 290, 430, 580, 360, 470, 240]
        for (index, height) in heights.enumerated() {
            context.setFillColor(CGColor(red: 0.27, green: 0.92, blue: 0.65, alpha: 1))
            let rect = CGRect(x: 226 + CGFloat(index) * 84, y: 512 - height / 2, width: 54, height: height)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 27, cornerHeight: 27, transform: nil))
            context.fillPath()
        }
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fatalError("Could not encode an icon bitmap")
        }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
print(iconset.path)
