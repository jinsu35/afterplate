import Foundation

/// Where one dish name ends and the next begins, when the person typed them
/// by hand.
///
/// The predecessor engine settled this twice, and the reasoning is
/// worth keeping verbatim:
///
/// - A comma is an absolute boundary. "돈까스, 김밥" is two dishes, always.
/// - A space is not. Menu names are full of spaces — 트리플 초콜렛 쿠키 is one
///   cookie, not three — so splitting on spaces turns every long name into
///   nonsense.
/// - Which leaves the genuinely undecidable case: 돈까스 김밥, 티라미수 테린느.
///   Both readings are real menus somewhere. Its conclusion was that the
///   machine cannot know, and must not pretend either way — but also must not
///   stop and ask before doing the work. So it takes the default reading (one
///   dish), gets on with it, and offers a one-tap correction next to the
///   result. Right most of the time costs the person nothing; wrong costs one
///   tap.
///
/// This is the detector for that offer. It only speaks when both halves are
/// dishes it actually knows — a name this place prints, or a dish from the
/// dictionary — so a long menu name it has never seen stays untouched.
enum DishPhrase {
    /// A name the person typed that could be read as two.
    struct Ambiguity {
        let whole: String
        let parts: [String]
        /// The same field with a comma put in, ready to replace it with.
        var separated: String { parts.joined(separator: ", ") }
    }

    /// nil when there is nothing to ask about: a comma settles it, a name the
    /// menu prints settles it, and a phrase whose halves are not both known
    /// dishes is left alone.
    static func ambiguity(in text: String, menu: [String], vocabulary: [String]) -> Ambiguity? {
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty, !whole.contains(","), !whole.contains("，"), !whole.contains("·") else { return nil }
        let words = whole.split(separator: " ").map(String.init)
        guard words.count >= 2, words.count <= 6 else { return nil }

        let printed = Set(menu.map(flat))
        // This place prints it: one dish, whatever the dictionary thinks.
        if printed.contains(flat(whole)) { return nil }
        let known = printed.union(vocabulary.map(flat))

        // Prefer the split the menu itself supports; fall back to the
        // dictionary. Several possible splits mean the phrase is too tangled
        // to offer a clean correction — say nothing.
        var found: [String]?
        for cut in 1..<words.count {
            let left = words[..<cut].joined(separator: " ")
            let right = words[cut...].joined(separator: " ")
            guard known.contains(flat(left)), known.contains(flat(right)) else { continue }
            if found != nil { return nil }
            found = [left, right]
        }
        guard let parts = found else { return nil }
        return Ambiguity(whole: whole, parts: parts)
    }

    private static func flat(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.lowercased()
    }
}
