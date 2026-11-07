import AppKit
import Vision

/// Reads text from a screen area or a copied image. Recognition runs on this Mac only.
enum TextRecognizer {
    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Correction assumes English and would change words in other languages.
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return "" }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    static func recognize(file: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return "" }
        return recognize(image)
    }
}

@MainActor
enum TextCapture {
    private static var isCapturing = false

    /// Lets the user drag over part of the screen, then copies the text found there.
    static func run(into history: ClipboardHistory) {
        guard !isCapturing else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            HintToast.show("Allow Screen Recording for DyskLink, then try again")
            return
        }
        isCapturing = true
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dysklink-\(UUID().uuidString).png")
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", file.path]
            let started = (try? process.run()) != nil
            if started { process.waitUntilExit() }
            // Pressing Escape during the capture leaves no file.
            let wasCanceled = !FileManager.default.fileExists(atPath: file.path)
            let text = wasCanceled ? "" : TextRecognizer.recognize(file: file)
            try? FileManager.default.removeItem(at: file)
            await MainActor.run {
                isCapturing = false
                if !wasCanceled { deliver(text, to: history) }
            }
        }
    }

    static func deliver(_ text: String, to history: ClipboardHistory) {
        guard !text.isEmpty else { return HintToast.show("No text found") }
        history.copy(text: text)
        HintToast.show("Text copied")
    }
}
