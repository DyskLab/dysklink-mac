import AppKit
import SwiftUI

/// DyskLink logo: a cable with two plugs, drawn on a 24x24 box.
/// Same coordinates as ic_logo_glyph.xml in the Android app.
struct LogoGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var cable = Path()
        cable.move(to: CGPoint(x: 6.5, y: 10))
        cable.addLine(to: CGPoint(x: 6.5, y: 18.25))
        cable.addArc(center: CGPoint(x: 9.25, y: 18.25), radius: 2.75,
                     startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        cable.addLine(to: CGPoint(x: 12, y: 6))
        cable.addArc(center: CGPoint(x: 14.75, y: 6), radius: 2.75,
                     startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        cable.addLine(to: CGPoint(x: 17.5, y: 13))

        var prongs = Path()
        for (x, start, end) in [(5.0, 2.75, 5.5), (8.0, 2.75, 5.5), (16.0, 17.5, 20.25), (19.0, 17.5, 20.25)] {
            prongs.move(to: CGPoint(x: x, y: start))
            prongs.addLine(to: CGPoint(x: x, y: end))
        }

        var bodies = Path()
        bodies.addRoundedRect(
            in: CGRect(x: 3.5, y: 5.5, width: 6, height: 4.5),
            cornerRadii: RectangleCornerRadii(bottomLeading: 2.5, bottomTrailing: 2.5)
        )
        bodies.addRoundedRect(
            in: CGRect(x: 14.5, y: 13, width: 6, height: 4.5),
            cornerRadii: RectangleCornerRadii(topLeading: 2.5, topTrailing: 2.5)
        )

        // Must be a union. If merely stacked, opposite path directions punch holes in the overlaps.
        let result = cable.strokedPath(StrokeStyle(lineWidth: 1.9, lineCap: .round))
            .union(prongs.strokedPath(StrokeStyle(lineWidth: 1.5, lineCap: .round)))
            .union(bodies)

        let scale = min(rect.width, rect.height) / 24
        return result.applying(
            CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
                .scaledBy(x: scale, y: scale)
        )
    }

    /// Menu bar icon. Its color follows the menu bar theme because it is a template image.
    static func menuBarImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(LogoGlyph().path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
