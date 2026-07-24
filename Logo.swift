// The Bubo mark: an eagle-owl face, drawn from plain shapes so one definition
// serves the README, the .icns, and the DMG. Render with `Bubo --icon <dir>`.

import SwiftUI
import AppKit

struct OwlMark: View {
    /// Everything below is laid out on a 1024 grid, then scaled.
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 228, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.15, green: 0.17, blue: 0.26),
                             Color(red: 0.07, green: 0.08, blue: 0.13)],
                    startPoint: .top, endPoint: .bottom))

            owl
        }
        .frame(width: 1024, height: 1024)
    }

    private var owl: some View {
        ZStack {
            tufts
            // face disc, a shade lighter than the night background
            Circle()
                .fill(Color(red: 0.25, green: 0.29, blue: 0.42))
                .frame(width: 660, height: 660)
                .offset(y: 40)
            eyes
            beak
        }
    }

    /// The ear tufts an eagle-owl is known for, angled outward.
    private var tufts: some View {
        ForEach([-1.0, 1.0], id: \.self) { side in
            Triangle()
                .fill(Color(red: 0.25, green: 0.29, blue: 0.42))
                .frame(width: 210, height: 260)
                .rotationEffect(.degrees(side * 18))
                .offset(x: side * 205, y: -215)
        }
    }

    private var eyes: some View {
        ForEach([-1.0, 1.0], id: \.self) { side in
            ZStack {
                Circle()                                   // amber iris
                    .fill(LinearGradient(
                        colors: [Color(red: 0.98, green: 0.79, blue: 0.36),
                                 Color(red: 0.90, green: 0.60, blue: 0.13)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: 236, height: 236)
                Circle()                                   // pupil
                    .fill(Color(red: 0.05, green: 0.05, blue: 0.09))
                    .frame(width: 104, height: 104)
                Circle()                                   // catchlight, keeps it alive
                    .fill(.white.opacity(0.9))
                    .frame(width: 36, height: 36)
                    .offset(x: -30, y: -34)
            }
            .offset(x: side * 132, y: -22)
        }
    }

    private var beak: some View {
        Triangle()
            .fill(LinearGradient(
                colors: [Color(red: 0.94, green: 0.70, blue: 0.24),
                         Color(red: 0.82, green: 0.48, blue: 0.10)],
                startPoint: .top, endPoint: .bottom))
            .rotationEffect(.degrees(180))
            .frame(width: 92, height: 132)
            .offset(y: 188)
    }
}

/// Isoceles triangle pointing up.
struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Write every size `iconutil` needs, plus a plain logo.png for the README.
@MainActor func renderIcons(to dir: String) {
    let fm = FileManager.default
    let iconset = "\(dir)/Bubo.iconset"
    try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

    func write(_ px: Int, _ path: String) {
        let r = ImageRenderer(content: OwlMark())
        r.scale = Double(px) / 1024.0
        guard let tiff = r.nsImage?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("failed at \(px)px"); exit(1)
        }
        try! png.write(to: URL(fileURLWithPath: path))
    }

    // iconutil expects both the 1x and 2x file for each logical size
    for size in [16, 32, 128, 256, 512] {
        write(size, "\(iconset)/icon_\(size)x\(size).png")
        write(size * 2, "\(iconset)/icon_\(size)x\(size)@2x.png")
    }
    write(512, "\(dir)/logo.png")
    print("wrote \(iconset) and \(dir)/logo.png")
}
