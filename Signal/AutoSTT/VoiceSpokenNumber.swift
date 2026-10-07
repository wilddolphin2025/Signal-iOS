//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Turns spoken numbers ("plus one six five oh…") into digits, and reads digits back one by one.
enum VoiceSpokenNumber {
    /// `plus` is true when the person said "plus" or the text started with `+`.
    static func parse(_ text: String, languageCode: String) -> (plus: Bool, digits: String)? {
        let tokens = VoiceCommandParser.tokenize(text)
        var plus = text.contains("+")
        var digits = ""
        var pendingRepeat = 1
        let words = Self.words(languageCode)
        for token in tokens {
            if words.plus.contains(token) { plus = true; continue }
            if let times = words.repeats[token] { pendingRepeat = times; continue }
            if token.allSatisfy(\.isNumber) {
                digits += String(repeating: token, count: pendingRepeat)
                pendingRepeat = 1
                continue
            }
            if let digit = words.digit[token] {
                digits += String(repeating: digit, count: pendingRepeat)
                pendingRepeat = 1
                continue
            }
            pendingRepeat = 1
        }
        guard digits.count >= 7 else { return nil }
        return (plus, digits)
    }

    static func looksLikeNumber(_ text: String, languageCode: String) -> Bool {
        parse(text, languageCode: languageCode) != nil
    }

    /// "plus 1, 6 5 0, 4 5 0, 8 0 2 5" so the listener can catch a wrong digit.
    static func spoken(_ e164: String, languageCode: String) -> String {
        var digits = e164
        var prefix = ""
        if digits.hasPrefix("+") {
            prefix = languageCode == "es" ? "más " : languageCode == "ru" ? "плюс " : "plus "
            digits.removeFirst()
        }
        var groups: [String] = []
        if digits.count > 10 {
            groups.append(String(digits.prefix(digits.count - 10)))
            digits = String(digits.suffix(10))
        }
        while !digits.isEmpty {
            let n = digits.count == 4 ? 4 : min(3, digits.count)
            groups.append(digits.prefix(n).map(String.init).joined(separator: " "))
            digits.removeFirst(n)
        }
        return prefix + groups.joined(separator: ", ")
    }

    static func countryRegion(from text: String, languageCode: String) -> String? {
        let tokens = Set(VoiceCommandParser.tokenize(text))
        let table = countries(languageCode)
        if let exact = table.first(where: { $0.0 == tokens.sorted().joined(separator: " ") }) { return exact.1 }
        return table.first(where: { tokens.contains($0.0) })?.1
    }

    // MARK: Vocabulary

    private struct Words {
        var plus: Set<String>
        var digit: [String: String]
        var repeats: [String: Int]
    }

    private static func words(_ language: String) -> Words {
        switch language {
        case "es":
            Words(
                plus: ["mas", "plus"],
                digit: [
                    "cero": "0", "zero": "0", "oh": "0",
                    "uno": "1", "una": "1", "un": "1",
                    "dos": "2", "tres": "3", "cuatro": "4", "cinco": "5",
                    "seis": "6", "siete": "7", "ocho": "8", "nueve": "9",
                ],
                repeats: ["doble": 2, "triple": 3],
            )
        case "ru":
            Words(
                plus: ["плюс", "plus"],
                digit: [
                    "ноль": "0", "нуль": "0",
                    "один": "1", "одна": "1", "раз": "1",
                    "два": "2", "две": "2", "три": "3", "четыре": "4", "пять": "5",
                    "шесть": "6", "семь": "7", "восемь": "8", "девять": "9",
                ],
                repeats: ["дважды": 2, "двойной": 2, "трижды": 3, "тройной": 3],
            )
        default:
            Words(
                plus: ["plus"],
                digit: [
                    "zero": "0", "oh": "0", "o": "0",
                    "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
                    "six": "6", "seven": "7", "eight": "8", "nine": "9",
                ],
                repeats: ["double": 2, "triple": 3],
            )
        }
    }

    private static func countries(_ language: String) -> [(String, String)] {
        let names: [(String, String)] = [
            ("united states", "US"), ("america", "US"), ("usa", "US"), ("us", "US"), ("states", "US"),
            ("canada", "CA"), ("mexico", "MX"), ("uk", "GB"), ("britain", "GB"), ("england", "GB"),
            ("spain", "ES"), ("espana", "ES"), ("france", "FR"), ("germany", "DE"),
            ("russia", "RU"), ("ukraine", "UA"), ("israel", "IL"), ("india", "IN"),
            ("brazil", "BR"), ("australia", "AU"), ("japan", "JP"), ("china", "CN"),
            ("estados unidos", "US"), ("eeuu", "US"), ("mexico", "MX"), ("espana", "ES"),
            ("reino unido", "GB"), ("francia", "FR"), ("alemania", "DE"), ("rusia", "RU"),
            ("сша", "US"), ("америка", "US"), ("канада", "CA"), ("мексика", "MX"),
            ("англия", "GB"), ("британия", "GB"), ("испания", "ES"), ("франция", "FR"),
            ("германия", "DE"), ("россия", "RU"), ("украина", "UA"), ("израиль", "IL"),
        ]
        return names.map { (VoiceCommandParser.tokenize($0.0).joined(separator: " "), $0.1) }
    }
}
