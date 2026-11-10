import AppKit

// Renders text centered on a 160x80 black PNG. Usage: swift text-png.swift "some text" out.png
let args = CommandLine.arguments
guard args.count == 3 else { print("usage: text-png.swift TEXT OUT.png"); exit(1) }
let (text, outPath) = (args[1], args[2])

let w = 160, h = 80
let image = NSImage(size: NSSize(width: w, height: h))
image.lockFocus()
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: w, height: h).fill()

let para = NSMutableParagraphStyle()
para.alignment = .center
var fontSize: CGFloat = 44
var attrs: [NSAttributedString.Key: Any] = [:]
var size = NSSize.zero
repeat {
    attrs = [
        .font: NSFont.boldSystemFont(ofSize: fontSize),
        .foregroundColor: NSColor.white,
        .paragraphStyle: para,
    ]
    let s = (text as NSString).size(withAttributes: attrs)
    size = s
    fontSize -= 3
} while size.width > CGFloat(w - 10) && fontSize > 8

let rect = NSRect(x: 0, y: (CGFloat(h) - size.height) / 2, width: CGFloat(w), height: size.height)
(text as NSString).draw(in: rect, withAttributes: attrs)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("encode failed"); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(png.count) bytes)")
