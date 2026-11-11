import AppKit
import CoreText
import PDFKit
import Vision

/// Adds an invisible text layer to a scanned PDF, so Spotlight, Preview, and other apps can search and copy its text.
/// The pages are kept exactly as they were; the recognised text is drawn under them in invisible ink.
enum SearchablePDF {
    /// The long side pages are read at, in pixels.
    static let readSide: CGFloat = 2400

    /// Returns how many pages got text. A PDF that already has text is left alone.
    @discardableResult
    static func addText(to url: URL) -> Int {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0,
              (PDFDocument(url: url)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        guard let context = CGContext(temporary as CFURL, mediaBox: nil, nil) else { return 0 }
        var withText = 0
        for number in 1...document.numberOfPages {
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.mediaBox)
            let rotation = ((page.rotationAngle % 360) + 360) % 360
            let shown = rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
            var mediaBox = CGRect(origin: .zero, size: shown)
            let info = [kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            let lines = image(of: page, size: shown).map(read) ?? []
            if !lines.isEmpty { withText += 1 }
            draw(lines, in: context, size: shown)
            // The page goes on top, so the text never shows, whatever the viewer does with invisible text.
            context.saveGState()
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: mediaBox, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        guard withText > 0 else {
            try? FileManager.default.removeItem(at: temporary)
            return 0
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            return withText
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return 0
        }
    }

    /// The page drawn on white, the way it looks.
    static func image(of page: CGPDFPage, size: CGSize) -> CGImage? {
        let scale = readSide / max(size.width, size.height, 1)
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0,
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        bitmap.setFillColor(.white)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        bitmap.concatenate(page.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        bitmap.drawPDFPage(page)
        return bitmap.makeImage()
    }

    struct Line {
        var text: String
        /// 0…1 of the page, from the bottom left, as Vision gives it.
        var box: CGRect
    }

    static func read(_ image: CGImage) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { result in
            guard let text = result.topCandidates(1).first?.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return Line(text: text, box: result.boundingBox)
        }
    }

    /// Each line stretched over the place it was read from, so selecting text in a viewer lines up with the picture.
    static func draw(_ lines: [Line], in context: CGContext, size: CGSize) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(x: line.box.minX * size.width, y: line.box.minY * size.height,
                              width: line.box.width * size.width, height: line.box.height * size.height)
            guard rect.width > 1, rect.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.8, nil)
            let text = NSAttributedString(string: line.text, attributes: [.init(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(text)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard width > 0 else { continue }
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.2)
            context.scaleBy(x: rect.width / CGFloat(width), y: 1)
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}
