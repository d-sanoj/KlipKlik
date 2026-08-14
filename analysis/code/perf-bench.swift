// Harnesses behind 14-performance.md.
//
// Standalone except for the image round-trip, which compiles against the
// shipped ClipboardItem:
//
//   swiftc -O -o /tmp/perf analysis/code/perf-bench.swift
//   /tmp/perf tcc
//   /tmp/perf encode  <some.png>
//   /tmp/perf hash    <some.tiff>
//
//   swiftc -O -o /tmp/rt analysis/code/image-roundtrip.swift \
//       Sources/KlipKlick/Models/ClipboardItem.swift
//   /tmp/rt <some.png>

import AppKit
import CryptoKit
import CoreGraphics
import Foundation
import ApplicationServices

func fastest(_ label: String, _ runs: Int = 5, _ body: () -> Void) {
    body()  // warm
    var best = Double.infinity
    for _ in 0..<runs {
        let start = Date()
        body()
        best = min(best, Date().timeIntervalSince(start) * 1000)
    }
    print(String(format: "%-34s %8.2f ms", (label as NSString).utf8String!, best))
}

/// What one tick of the leaked 1 Hz permission timer actually cost.
///
/// The interesting part is the split: almost none of it is CPU. It is the main
/// thread blocked on an XPC round trip to tccd, which is why the leak never
/// showed up as CPU time in Activity Monitor.
func tccCost() {
    func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = { (t: timeval) in Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    fastest("AXIsProcessTrusted()") { _ = AXIsProcessTrusted() }

    _ = CGPreflightScreenCaptureAccess()
    let runs = 500
    let wallStart = Date(), cpuStart = cpuSeconds()
    for _ in 0..<runs { _ = CGPreflightScreenCaptureAccess() }
    let wall = Date().timeIntervalSince(wallStart) / Double(runs) * 1000
    let cpu = (cpuSeconds() - cpuStart) / Double(runs) * 1000

    print(String(format: "CGPreflightScreenCaptureAccess()   %.2f ms wall, %.2f ms CPU, %.2f ms blocked",
                 wall, cpu, wall - cpu))
    print(String(format: "  at the leaked 1 Hz: %.2f%% of the main thread, %.2f%% CPU", wall / 10, cpu / 10))
}

/// JSON against binary property list for the offload blobs.
///
/// JSON cannot hold bytes, so every Data goes out as base64.
func encodingCost(_ path: String) {
    let payload = try! Data(contentsOf: URL(fileURLWithPath: path))
    let bags: [[String: Data]] = [["public.png": payload]]
    let plist = PropertyListEncoder()
    plist.outputFormat = .binary

    print(String(format: "payload %.1f KB", Double(payload.count) / 1024))
    print(String(format: "JSON  encodes to %.1f KB", Double(try! JSONEncoder().encode(bags).count) / 1024))
    print(String(format: "plist encodes to %.1f KB", Double(try! plist.encode(bags).count) / 1024))

    fastest("JSON encode") { _ = try! JSONEncoder().encode(bags) }
    fastest("binary plist encode") { _ = try! plist.encode(bags) }

    let json = try! JSONEncoder().encode(bags), binary = try! plist.encode(bags)
    fastest("JSON decode") { _ = try! JSONDecoder().decode([[String: Data]].self, from: json) }
    fastest("binary plist decode") { _ = try! PropertyListDecoder().decode([[String: Data]].self, from: binary) }
}

/// Fingerprint hashing. `hashValue` is fastest and unusable — Swift seeds it per
/// process, so it does not survive a relaunch.
func hashCost(_ path: String) {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    print(String(format: "payload %.1f MB", Double(data.count) / 1024 / 1024))

    fastest("SHA256, whole payload") { _ = SHA256.hash(data: data) }
    fastest("SHA256, count + 64KB ends") {
        var hasher = SHA256()
        var count = data.count
        withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data.prefix(65536))
        hasher.update(data: data.suffix(65536))
        _ = hasher.finalize()
    }
    fastest("Data.hashValue (unstable)") { _ = data.hashValue }
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "tcc": tccCost()
case "encode": encodingCost(args[2])
case "hash": hashCost(args[2])
default: print("usage: perf-bench tcc | encode <png> | hash <file>")
}
