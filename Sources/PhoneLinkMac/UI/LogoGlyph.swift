import AppKit
import SwiftUI

/// DyskLink logo: an open ring around two joined points, drawn on a 24x24 box. The ring matches the other DyskLab apps.
/// Same coordinates as ic_logo_glyph.xml in the Android app.
struct LogoGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var ring = Path()
        ring.addArc(center: CGPoint(x: 12, y: 12.49), radius: 7.2,
                    startAngle: .degrees(-101.42), endAngle: .degrees(-400.22), clockwise: true)

        var line = Path()
        line.move(to: CGPoint(x: 9.4, y: 14.49))
        line.addLine(to: CGPoint(x: 14.6, y: 10.49))

        var nodes = Path()
        nodes.addEllipse(in: CGRect(x: 7.75, y: 12.84, width: 3.3, height: 3.3))
        nodes.addEllipse(in: CGRect(x: 12.95, y: 8.84, width: 3.3, height: 3.3))

        // Must be a union. If merely stacked, opposite path directions punch holes in the overlaps.
        let result = ring.strokedPath(StrokeStyle(lineWidth: 1.69, lineCap: .round))
            .union(line.strokedPath(StrokeStyle(lineWidth: 1.69, lineCap: .round)))
            .union(nodes)

        let scale = min(rect.width, rect.height) / 24
        return result.applying(
            CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
                .scaledBy(x: scale, y: scale)
        )
    }

    /// Menu bar icon. Its color follows the menu bar theme because it is a template image.
    /// The ring fills the icon here, since the empty part of the 24x24 box would make it look small.
    static func menuBarImage() -> NSImage { menuBarCache }

    /// Drawn once; the menu bar label asks for it on every redraw.
    private static let menuBarCache: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(LogoGlyph().path(in: CGRect(x: -3, y: -3.49, width: 24, height: 24)).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
