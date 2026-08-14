// Proves the image compaction in 14-performance.md is lossless.
//
// Compiles against the shipped model, so it exercises the code that actually
// runs — not a copy of it:
//
//   swiftc -O -o /tmp/rt analysis/code/image-roundtrip.swift \
//       Sources/KlipKlick/Models/ClipboardItem.swift
//   /tmp/rt <some.png>
//
// The claim under test: storing PNG in place of the pasteboard's uncompressed
// TIFF costs nothing, because write(to:) rebuilds the TIFF byte for byte.

import AppKit

// @main rather than top-level code: this is compiled alongside ClipboardItem.swift,
// and only a file named main.swift may carry statements at the top level.
@main
enum RoundTrip {
static func main() {
let tiff = NSImage(contentsOfFile: CommandLine.arguments[1])!.tiffRepresentation!
let original: [[String: Data]] = [["public.tiff": tiff]]

guard let result = ClipboardItem.compacting(original) else {
    print("FAIL: compacting returned nil")
    exit(1)
}

let before = original[0].values.reduce(0) { $0 + $1.count }
let after = result.bags[0].values.reduce(0) { $0 + $1.count }
print(String(format: "stored: %.1f KB -> %.1f KB (%.0f%% smaller), restoresTIFF=%@",
             Double(before) / 1024, Double(after) / 1024,
             100 - Double(after) / Double(before) * 100, "\(result.restoresTIFF)"))
print("kept flavours: \(result.bags[0].keys.sorted())")

let item = ClipboardItem(
    kind: .image, title: "roundtrip", plainText: nil, representations: result.bags,
    fingerprint: "f", restoresTIFF: result.restoresTIFF
)

// A named pasteboard, so running this never disturbs the real clipboard.
let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.sanoj.KlipKlick.roundtrip"))
item.write(to: pasteboard)

guard let pasted = pasteboard.pasteboardItems?.first else {
    print("FAIL: nothing written")
    exit(1)
}
print("pasted flavours: \(pasted.types.map(\.rawValue).sorted())")

guard let restored = pasted.data(forType: .tiff) else {
    print("FAIL: no public.tiff on paste — an app asking only for TIFF gets nothing")
    exit(1)
}

let identicalBytes = restored == tiff
let a = NSBitmapImageRep(data: tiff)!, b = NSBitmapImageRep(data: restored)!
let identicalPixels = a.representation(using: .png, properties: [:])
    == b.representation(using: .png, properties: [:])

print("restored \(restored.count) bytes vs original \(tiff.count)")
print("identical bytes: \(identicalBytes), identical pixels: \(identicalPixels)")
print(identicalPixels ? "PASS" : "FAIL: pixels differ")
}
}
