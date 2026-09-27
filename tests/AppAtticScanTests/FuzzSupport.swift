import Foundation

/// Deterministic byte source for the fuzz harnesses below. The toolchain
/// here has no libFuzzer, so mutation is seeded by hand: a fixed seed list
/// means a failure names the seed that produced it and replays exactly.
struct FuzzRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x0123_4567_89AB_CDEF
    }

    /// splitmix64.
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(next() % UInt64(bound))
    }

    mutating func element<T>(_ values: [T]) -> T {
        values[int(values.count)]
    }
}

/// Corpus-shaped mutation: the seeds below are real command output, and the
/// edits are the ones that break hand-rolled line parsers (cut a line in half,
/// duplicate a delimiter, drop a bracket, splice a control byte, truncate).
enum FuzzMutator {
    /// NUL and the C0 controls, a BOM, every delimiter the listing parsers
    /// split on, and multi-byte UTF-8 in three widths.
    static let hotBytes: [UInt8] = [
        0x00, 0x09, 0x0A, 0x0D, 0x1B, 0x7F, 0x20, 0x7C, 0x5B, 0x5D, 0x40,
        0x2D, 0x2B, 0x3A, 0x2E, 0x2C, 0xEF, 0xBB, 0xBF, 0xC3, 0xA9,
        0xE2, 0x94, 0x80, 0xF0, 0x9F, 0x92, 0xA9,
    ]

    /// The ASCII half of `hotBytes`, for a harness that holds two readers of
    /// one file against each other and can only require them to agree where
    /// the byte and the Unicode reading of a character are the same.
    static let asciiHotBytes: [UInt8] = hotBytes.filter { $0 < 0x80 }

    /// Largest output a harness builds, so one seed cannot turn into a
    /// multi-megabyte line the parser has to walk per iteration.
    static let maxBytes = 8192

    static func bytes(
        from seed: [UInt8],
        using rng: inout FuzzRandom,
        hotBytes: [UInt8] = FuzzMutator.hotBytes
    ) -> [UInt8] {
        var out = seed
        for _ in 0...(1 + rng.int(8)) {
            guard !out.isEmpty else { break }
            switch rng.int(6) {
            case 0:
                out[rng.int(out.count)] = rng.element(hotBytes)
            case 1:
                out.insert(rng.element(hotBytes), at: rng.int(out.count))
            case 2:
                out.remove(at: rng.int(out.count))
            case 3:
                out = Array(out[0..<rng.int(out.count)])
            case 4:
                let start = rng.int(out.count)
                out.append(contentsOf: seed)
                out.append(contentsOf: seed[0..<min(start, seed.count)])
            default:
                let start = rng.int(out.count)
                out.removeSubrange(start..<min(out.count, start + 1 + rng.int(16)))
            }
            if out.count > maxBytes { out.removeLast(out.count - maxBytes) }
        }
        return out
    }

    static func text(
        from seed: String,
        using rng: inout FuzzRandom,
        hotBytes: [UInt8] = FuzzMutator.hotBytes
    ) -> String {
        String(decoding: bytes(from: Array(seed.utf8), using: &rng, hotBytes: hotBytes), as: UTF8.self)
    }
}

/// Seeds the harnesses iterate. A crash names the index, so the failing input
/// is reproducible without a fuzzer log.
let fuzzSeeds: [UInt64] = (0..<400).map { UInt64($0) &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
