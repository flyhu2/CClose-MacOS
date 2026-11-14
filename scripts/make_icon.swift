import AppKit
import Foundation
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
func rounded(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
        let transform = AffineTransform(scale: CGFloat(size) / 1024)
        (transform as NSAffineTransform).concat()
        NSGradient(starting: color(0.737, 0.933, 0.882), ending: color(0.471, 0.749, 0.773))!.draw(in: rounded(NSRect(x: 64, y: 64, width: 896, height: 896), 208), angle: 60)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let back = rounded(NSRect(x: 232, y: 342, width: 460, height: 390), 66); back.lineWidth = 32; back.stroke()
        NSColor.white.setFill(); rounded(NSRect(x: 332, y: 240, width: 460, height: 390), 66).fill()
        color(0.224, 0.549, 0.588).setStroke()
        let bar = NSBezierPath(); bar.move(to: NSPoint(x: 388, y: 330)); bar.line(to: NSPoint(x: 478, y: 330)); bar.lineWidth = 22; bar.lineCapStyle = .round; bar.stroke()
        color(0.224, 0.549, 0.588).setFill()
        let pin = NSBezierPath()
        let points: [NSPoint] = [.init(x:589,y:333),.init(x:683,y:333),.init(x:667,y:403),.init(x:704,y:442),.init(x:704,y:466),.init(x:644,y:466),.init(x:644,y:556),.init(x:628,y:556),.init(x:628,y:466),.init(x:568,y:466),.init(x:568,y:442),.init(x:605,y:403)]
        pin.move(to: points[0]); for p in points.dropFirst() { pin.line(to:p) }; pin.close(); pin.fill()
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = rep.representation(using: .png, properties: [:])!
    if size <= 512 { try data.write(to: URL(fileURLWithPath: "\(output)/icon_\(size)x\(size).png")) }
    if size >= 32 { try data.write(to: URL(fileURLWithPath: "\(output)/icon_\(size/2)x\(size/2)@2x.png")) }
}
