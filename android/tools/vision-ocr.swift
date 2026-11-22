// Runs Apple's Vision OCR on an image and prints each recognised line with its four corners in pixel coordinates
// (origin top-left, y down), the same shape as ML Kit's Text.Line.cornerPoints. Used to build a test fixture.
import Foundation
import Vision
import AppKit

let path = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: path), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
let W = Double(cg.width), H = Double(cg.height)
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: cg).perform([req])
var out: [[String: Any]] = []
for obs in req.results ?? [] {
    guard let top = obs.topCandidates(1).first else { continue }
    func p(_ q: CGPoint) -> [Double] { [q.x * W, (1 - q.y) * H] }
    out.append(["text": top.string, "corners": [p(obs.topLeft), p(obs.topRight), p(obs.bottomRight), p(obs.bottomLeft)]])
}
let data = try JSONSerialization.data(withJSONObject: ["width": W, "height": H, "lines": out], options: [.prettyPrinted])
FileHandle.standardOutput.write(data)
