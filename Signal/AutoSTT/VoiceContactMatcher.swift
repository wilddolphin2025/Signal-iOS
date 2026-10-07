//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

struct VoiceContact: Hashable {
    let id: String
    let name: String
    let isGroup: Bool
    /// Lower is more recent; used to order equally good matches.
    let recency: Int
    fileprivate let keys: [String]

    init(id: String, name: String, isGroup: Bool, recency: Int) {
        self.id = id
        self.name = name
        self.isGroup = isGroup
        self.recency = recency
        self.keys = VoiceContactMatcher.keys(name)
    }
}

/// Finds contacts by spoken name. Names and speech are both reduced to a phonetic Latin key, so
/// "Masha", "Маша" and "Маше" meet, and recognizer misspellings still land on the right person.
struct VoiceContactMatcher {
    enum Result: Equatable {
        case none(suggestion: VoiceContact?)
        case one(VoiceContact, confident: Bool)
        case several([VoiceContact])
    }

    let contacts: [VoiceContact]

    func match(_ query: String, within pool: [VoiceContact]? = nil, groupsOnly: Bool = false, languageCode: String) -> Result {
        var tokens = Self.keys(query)
        if tokens.count > 1, tokens.allSatisfy({ $0.count == 1 }) { tokens = [Self.phonetic(tokens.joined())] }
        guard !tokens.isEmpty else { return .none(suggestion: nil) }
        let inflected = languageCode == "ru"
        let scored = (pool ?? contacts)
            .filter { !groupsOnly || $0.isGroup }
            .map { ($0, Self.score(tokens, $0.keys, inflected: inflected)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.recency < $1.0.recency }
        let threshold = pool == nil ? 0.72 : 0.6
        guard let best = scored.first, best.1 >= threshold else {
            return .none(suggestion: scored.first.flatMap { $0.1 >= 0.55 ? $0.0 : nil })
        }
        let close = scored.prefix { $0.1 >= best.1 - 0.06 }.map(\.0)
        if close.count == 1 { return .one(best.0, confident: best.1 >= 0.9) }
        return .several(close.sorted { $0.recency < $1.recency })
    }

    /// Phrases for the recognizer's vocabulary, most recent first.
    func vocabulary(limit: Int = 300) -> [String] {
        Array(contacts.sorted { $0.recency < $1.recency }.prefix(limit).map(\.name))
    }

    // MARK: Scoring

    private static func score(_ query: [String], _ name: [String], inflected: Bool) -> Double {
        guard !name.isEmpty else { return 0 }
        if query == name { return 1 }
        let total = query.reduce(0.0) { sum, q in sum + (name.map { similarity(q, $0, inflected: inflected) }.max() ?? 0) }
        return total / Double(query.count)
    }

    private static func similarity(_ q: String, _ n: String, inflected: Bool) -> Double {
        if q == n { return 1 }
        if inflected, let a = stem(q), a == stem(n) { return 0.95 }
        if q.count >= 3, n.hasPrefix(q) { return 0.8 + 0.1 * Double(q.count) / Double(n.count) }
        let jw = jaroWinkler(q, n)
        return jw >= 0.85 ? jw * 0.9 : 0
    }

    /// Russian names change their ending by case (Маша, Маше, Машу); compare without it.
    private static func stem(_ word: String) -> String? {
        var s = word
        for ending in ["om", "oi", "ei", "oiu", "eiu"] where s.count > ending.count + 2 && s.hasSuffix(ending) {
            s.removeLast(ending.count)
            break
        }
        var dropped = 0
        while dropped < 2, s.count > 3, let last = s.last, "aeiou".contains(last) {
            s.removeLast()
            dropped += 1
        }
        return s.count >= 3 ? s : nil
    }

    static func keys(_ text: String) -> [String] {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        return VoiceCommandParser.tokenize(latin.replacingOccurrences(of: "ʹ", with: "").replacingOccurrences(of: "ʺ", with: "")).map(phonetic)
    }

    private static func phonetic(_ word: String) -> String {
        var s = word
        for (from, to) in [("sch", "s"), ("sh", "s"), ("ch", "c"), ("zh", "z"), ("kh", "h"), ("ts", "c"), ("ph", "f"),
                           ("ck", "k"), ("x", "ks"), ("yu", "u"), ("ya", "a"), ("ye", "e"), ("j", "i"), ("y", "i"), ("w", "v")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        var out = ""
        for c in s where c != out.last { out.append(c) }
        return out
    }

    private static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let s = Array(a), t = Array(b)
        guard !s.isEmpty, !t.isEmpty else { return 0 }
        let window = max(0, max(s.count, t.count) / 2 - 1)
        var sMatched = [Bool](repeating: false, count: s.count), tMatched = [Bool](repeating: false, count: t.count)
        var matches = 0
        for i in s.indices where i - window < t.count {
            for j in max(0, i - window)..<min(t.count, i + window + 1) where !tMatched[j] && s[i] == t[j] {
                sMatched[i] = true
                tMatched[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }
        let sm = s.indices.filter { sMatched[$0] }.map { s[$0] }, tm = t.indices.filter { tMatched[$0] }.map { t[$0] }
        let transpositions = Double(zip(sm, tm).filter { $0 != $1 }.count) / 2
        let m = Double(matches)
        let jaro = (m / Double(s.count) + m / Double(t.count) + (m - transpositions) / m) / 3
        let prefix = Double(zip(s, t).prefix(4).prefix { $0 == $1 }.count)
        return jaro + prefix * 0.1 * (1 - jaro)
    }
}
