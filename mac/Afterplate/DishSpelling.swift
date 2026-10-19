import Foundation

/// Fixes a slip in a typed dish name against what the app already knows:
/// this restaurant's menu, the shipped dish dictionary and the dishes the
/// app has learned. Letters, not syllables, are compared — "차돌밖이" and
/// "차돌박이" differ by one jamo — and only a single-letter slip in a name of
/// three syllables or more is corrected, so 갈비 never becomes 갈치 and a
/// place's own spelling is left alone.
enum DishSpelling {
    /// The restaurant's own menu is tried first: its spelling wins over the
    /// dictionary's, and a tie there does not block the fix.
    static func corrected(_ typed: String, menu: [String], vocabulary: [String]) -> String? {
        corrected(typed, known: menu) ?? corrected(typed, known: menu + vocabulary)
    }

    static func corrected(_ typed: String, known: [String]) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 3, !name.isEmpty else { return nil }
        let candidates = known.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // Already a name the app knows: nothing to fix.
        if candidates.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return nil }
        let typedJamo = jamo(name)
        guard !typedJamo.isEmpty else { return nil }
        var best: (name: String, distance: Int)?
        for candidate in candidates {
            guard abs(candidate.count - name.count) <= 1 else { continue }
            let distance = levenshtein(typedJamo, jamo(candidate))
            guard distance <= 1 else { continue }
            if let current = best {
                // Two equally close names: too risky to guess between them.
                if distance == current.distance, candidate != current.name { return nil }
                if distance < current.distance { best = (candidate, distance) }
            } else {
                best = (candidate, distance)
            }
        }
        guard let best, best.distance == 1 else { return nil }
        return best.name
    }

    /// Hangul syllables split into their letters; everything else kept as is,
    /// lowercased, spaces dropped.
    private static func jamo(_ text: String) -> [UnicodeScalar] {
        var out: [UnicodeScalar] = []
        for scalar in text.lowercased().unicodeScalars where !CharacterSet.whitespaces.contains(scalar) {
            let value = scalar.value
            guard (0xAC00...0xD7A3).contains(value) else { out.append(scalar); continue }
            let index = value - 0xAC00
            let lead = index / (21 * 28), vowel = (index % (21 * 28)) / 28, tail = index % 28
            out.append(UnicodeScalar(0x1100 + lead)!)
            out.append(UnicodeScalar(0x1161 + vowel)!)
            if tail > 0 { out.append(UnicodeScalar(0x11A7 + tail)!) }
        }
        return out
    }

    private static func levenshtein(_ a: [UnicodeScalar], _ b: [UnicodeScalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
