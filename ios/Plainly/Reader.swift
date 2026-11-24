import PDFKit
import PlainlyCore
import UIKit
import Vision

/// Reads a report on this iPhone. Photos and PDF pages both go through Apple's Vision text recognition, then the same
/// rules as the web and Android apps rebuild the table. Nothing here touches the network.
enum Reader {
    struct Result {
        var tests: [LabTest]
        var meta: Meta
        var rows: [String]
    }

    static func read(image: UIImage) async throws -> Result {
        guard let cg = image.normalisedCGImage() else { throw ReadError.unreadable }
        let lines = try await ocr(cg)
        let rows = rowsFromLines(lines)
        return Result(tests: parseRows(rows), meta: parseMeta(rows), rows: rows)
    }

    /// A PDF's first page is rendered sharp and read the same way as a photo, so one reader handles both.
    static func read(pdf url: URL) async throws -> Result {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { throw ReadError.unreadable }
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2200 / max(box.width, box.height)
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height); ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        return try await read(image: img)
    }

    /// Vision's lines as text plus four corners in pixels (origin top-left, y down), the shape the row builder expects.
    static func ocr(_ cg: CGImage) async throws -> [OcrLine] {
        let w = Double(cg.width), h = Double(cg.height)
        return try await withCheckedThrowingContinuation { cont in
            let req = VNRecognizeTextRequest { req, err in
                if let err { cont.resume(throwing: err); return }
                let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
                cont.resume(returning: obs.compactMap { o in
                    guard let top = o.topCandidates(1).first else { return nil }
                    func p(_ q: CGPoint) -> (Double, Double) { (Double(q.x) * w, (1 - Double(q.y)) * h) }
                    return OcrLine(text: top.string, corners: [p(o.topLeft), p(o.topRight), p(o.bottomRight), p(o.bottomLeft)])
                })
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            do { try VNImageRequestHandler(cgImage: cg).perform([req]) } catch { cont.resume(throwing: error) }
        }
    }

    enum ReadError: LocalizedError {
        case unreadable, noResults
        var errorDescription: String? {
            switch self {
            case .unreadable: "That file couldn't be opened. Try a clear photo or the PDF from your lab."
            case .noResults: "No results were found. Try a clear, flat photo in good light, or the PDF from your lab."
            }
        }
    }
}

private extension UIImage {
    /// Vision reads pixels as stored, so a rotated camera photo is redrawn upright first.
    func normalisedCGImage() -> CGImage? {
        if imageOrientation == .up, let cg = cgImage { return cg }
        return UIGraphicsImageRenderer(size: size).image { _ in draw(in: CGRect(origin: .zero, size: size)) }.cgImage
    }
}
