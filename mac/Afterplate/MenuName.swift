import Foundation

/// A Google Maps menu prints both languages in one line ("고기 & 치폴레 살사
/// 부리또 볼 Meat & Chipotle Burrito Bowl"). The app shows the Korean half —
/// its own language — and keeps the printed English for the English review.
/// Rule only, no model: the split is where the Korean stops for good.
enum MenuName {
    static func hasHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    }

    static func split(_ printed: String) -> (korean: String, english: String) {
        let tokens = printed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return ("", "") }
        let hangul = CharacterSet(charactersIn: "가".unicodeScalars.first!..."힣".unicodeScalars.first!)
        let lastKorean = tokens.lastIndex { $0.unicodeScalars.contains(where: hangul.contains) }
        guard let lastKorean else { return ("", printed) }
        let korean = tokens[...lastKorean].joined(separator: " ")
        let english = tokens[(lastKorean + 1)...].joined(separator: " ")
        return (korean, english)
    }

    /// "Quattro Funghi (콰트로 풍기)" — a foreign name with its Korean in
    /// brackets — gives the Korean; anything else nil.
    static func bracketKorean(_ printed: String) -> String? {
        guard let open = printed.lastIndex(where: { $0 == "(" || $0 == "（" }),
              printed.hasSuffix(")") || printed.hasSuffix("）") else { return nil }
        let outside = printed[..<open]
        let inside = printed[printed.index(after: open)..<printed.index(before: printed.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        let hangul = { (s: Substring) in s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
        guard !inside.isEmpty, hangul(Substring(inside)), !hangul(outside) else { return nil }
        return inside
    }

    /// The name without a bracketed note at its end — an option or a
    /// description ("곱창 라면 (매운맛)", "샌드위치 세트 (Sandwich Set)").
    /// Nothing is cut if nothing would be left.
    static func withoutNote(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespaces)
        // A promotion in lenticular brackets, and its ♪★: "〖2H飲み放題付き♪〗
        // ちゃんぷるーコース" is the course.
        while let range = text.range(of: #"^\s*[【〖〔][^】〗〕]*[】〗〕]\s*"#, options: .regularExpression),
              range.upperBound < text.endIndex {
            text = String(text[range.upperBound...])
        }
        text = text.replacingOccurrences(of: #"[♪★☆]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        while let range = text.range(of: #"\s*[(（\[][^()（）\[\]]*[)）\]]\s*$"#, options: .regularExpression),
              range.lowerBound > text.startIndex {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        // A size at the end is an option too: "수육 소", "수육 대" are one
        // dish.
        if let range = text.range(of: #"\s+(소|중|대|특|S|M|L|Small|Medium|Large|Regular|[0-9]+인분?)$"#, options: .regularExpression),
           range.lowerBound > text.startIndex {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// What the caption field shows: Korean when the menu printed it.
    static func display(_ printed: String) -> String {
        let parts = split(printed)
        return parts.korean.isEmpty ? parts.english : parts.korean
    }
}
