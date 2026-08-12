// Benchmark for GlyphRepair. Compile against the shipped source:
//
//   mkdir -p /tmp/gb && cp analysis/code/glyph-bench.swift /tmp/gb/main.swift
//   swiftc -O -o /tmp/gb/run Sources/KlipKlick/Core/GlyphRepair.swift /tmp/gb/main.swift
//   /tmp/gb/run
//
// It has to be copied to main.swift: swiftc only allows top-level statements
// in a file with that name when compiling more than one file.
//
// Two things are measured, and both matter. Symbol recovery is the point of
// the feature. Prose safety is the guard: an earlier version scored well on
// symbols while turning real captured text into garbage.

import AppKit
import Vision

let symbolStrings = [
    "Press ⌘C to copy", "Use ⌘V to paste", "Hit ⌥⇧V for plain",
    "Try ⌃⌘F fullscreen", "Save with ⌘S now", "Undo is ⌘Z here",
    "Quit using ⌘Q please", "Open ⇧⌘P palette", "Find ⌘F in page",
    "Total: ¥300 paid", "Cost £45 today", "Price €20 net",
]

// Chosen to contain the letters most likely to be misfired on: H T t o a P E x f.
let proseStrings = [
    "The HTTP Host header", "let m = items.map { $0.name }",
    "Press to copy and paste", "Total items for the table",
    "Options and settings here", "Take the fast path first",
    "Header Price Total Count", "func handle(_ x: Int) -> Bool",
]

let sizes: [CGFloat] = [13, 16, 20, 24]
let fontKinds = ["system", "mono"]
let targetSymbols = Set("⌘⌥⇧⌃¥£€")

func render(_ text: String, _ pt: CGFloat, _ kind: String) -> CGImage {
    let font = kind == "mono"
        ? NSFont.monospacedSystemFont(ofSize: pt, weight: .regular)
        : NSFont.systemFont(ofSize: pt)
    let string = NSAttributedString(
        string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
    let bounds = string.boundingRect(
        with: NSSize(width: 2000, height: 400), options: [.usesLineFragmentOrigin])
    let w = Int(bounds.width + 30) * 2, h = Int(bounds.height + 30) * 2
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: 2, y: 2)
    let g = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
    string.draw(with: NSRect(x: 15, y: 15, width: bounds.width, height: bounds.height),
                options: [.usesLineFragmentOrigin])
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func recognise(_ img: CGImage) -> [VNRecognizedText] {
    let r = VNRecognizeTextRequest()
    r.recognitionLevel = .accurate
    r.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([r])
    return (r.results ?? []).compactMap { $0.topCandidates(1).first }
}

var symbolTotal = 0, symbolRecovered = 0, ocrAlone = 0
var proseTotal = 0, proseIntact = 0
var perSymbol: [Character: (hit: Int, total: Int)] = [:]
var perFont: [String: (hit: Int, total: Int)] = [:]
var damaged: [String] = []

let started = Date()

for pt in sizes {
    for kind in fontKinds {
        for truth in symbolStrings {
            let img = render(truth, pt, kind)
            let cands = recognise(img)
            let raw = cands.map(\.string).joined(separator: " ")
            let fixed = cands.map { GlyphRepair.repair($0, in: img) }.joined(separator: " ")
            for ch in truth where targetSymbols.contains(ch) {
                symbolTotal += 1
                var s = perSymbol[ch] ?? (0, 0); s.total += 1
                let key = "\(Int(pt))pt \(kind)"
                var f = perFont[key] ?? (0, 0); f.total += 1
                if fixed.contains(ch) { symbolRecovered += 1; s.hit += 1; f.hit += 1 }
                if raw.contains(ch) { ocrAlone += 1 }
                perSymbol[ch] = s; perFont[key] = f
            }
        }
        for truth in proseStrings {
            let img = render(truth, pt, kind)
            let cands = recognise(img)
            let raw = cands.map(\.string).joined(separator: " ")
            let fixed = cands.map { GlyphRepair.repair($0, in: img) }.joined(separator: " ")
            proseTotal += 1
            if raw == fixed { proseIntact += 1 } else { damaged.append("\(raw)  ->  \(fixed)") }
        }
    }
}

func pct(_ a: Int, _ b: Int) -> String {
    b == 0 ? "n/a" : String(format: "%.1f%%", 100.0 * Double(a) / Double(b))
}

print("symbol occurrences   : \(symbolTotal)")
print("  OCR alone got right: \(ocrAlone)  (\(pct(ocrAlone, symbolTotal)))")
print("  after repair       : \(symbolRecovered)  (\(pct(symbolRecovered, symbolTotal)))")
print("prose lines          : \(proseTotal)")
print("  left untouched     : \(proseIntact)  (\(pct(proseIntact, proseTotal)))")

print("\nper symbol:")
for (ch, v) in perSymbol.sorted(by: { $0.key < $1.key }) {
    print(String(format: "  %@  %3d/%3d  %6s", String(ch), v.hit, v.total,
                 (pct(v.hit, v.total) as NSString).utf8String!))
}
print("\nper size and font:")
for (k, v) in perFont.sorted(by: { $0.key < $1.key }) {
    print(String(format: "  %-12@ %3d/%3d  %@", k as NSString, v.hit, v.total,
                 pct(v.hit, v.total) as NSString))
}
if !damaged.isEmpty {
    print("\nPROSE DAMAGED:")
    for d in damaged.prefix(10) { print("  \(d)") }
}
print(String(format: "\nelapsed: %.1fs", Date().timeIntervalSince(started)))
