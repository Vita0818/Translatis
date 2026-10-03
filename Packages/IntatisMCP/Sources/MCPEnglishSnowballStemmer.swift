// English Snowball stemmer ported from rust-stemmers 1.2.0
// (CurrySoftware/rust-stemmers, crate commit
// af9d47d5a52eaaded088145bc7432403dbf706a5), including its generated form of
// the English Snowball algorithm.
//
// Local modifications: direct Swift translation over ASCII bytes after
// deunicode normalization; no Rust runtime dependency. The Snowball algorithm
// separately carries the BSD-3-Clause notice reproduced in
// ThirdPartyNotices/MCPToolSearch.md.
//
// MIT License
//
// Copyright (c) 2017 Jakob Demler
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation

/// A direct Swift port of the English Snowball program embedded by
/// rust-stemmers 1.2.0. Input is ASCII because bm25 2.3.2 normalizes with
/// deunicode before invoking the stemmer.
enum MCPEnglishSnowballStemmer {
    private static let lowercaseY = UInt8(ascii: "y")
    private static let markedY = UInt8(ascii: "Y")

    private static let exception1: [String: String] = [
        "andes": "andes",
        "atlas": "atlas",
        "bias": "bias",
        "cosmos": "cosmos",
        "dying": "die",
        "early": "earli",
        "gently": "gentl",
        "howe": "howe",
        "idly": "idl",
        "lying": "lie",
        "news": "news",
        "only": "onli",
        "singly": "singl",
        "skies": "sky",
        "skis": "ski",
        "sky": "sky",
        "tying": "tie",
        "ugly": "ugli",
    ]

    private static let exception2: Set<String> = [
        "succeed", "proceed", "exceed", "canning",
        "inning", "earring", "herring", "outing",
    ]

    static func stem(_ input: String) -> String {
        if let exceptional = exception1[input] {
            return exceptional
        }
        var word = Array(input.utf8)
        guard word.count >= 3 else {
            return input
        }

        prelude(&word)
        let r1 = firstRegion(in: word, after: 0)
        let r2 = firstRegion(in: word, after: r1)

        step0(&word)
        step1a(&word)
        if !exception2.contains(string(word)) {
            step1b(&word, r1: r1)
            step1c(&word)
            step2(&word, r1: r1)
            step3(&word, r1: r1, r2: r2)
            step4(&word, r2: r2)
            step5(&word, r1: r1, r2: r2)
        }
        for index in word.indices where word[index] == markedY {
            word[index] = lowercaseY
        }
        return string(word)
    }

    private static func prelude(_ word: inout [UInt8]) {
        if word.first == UInt8(ascii: "'") {
            word.removeFirst()
        }
        guard !word.isEmpty else { return }
        if word[0] == lowercaseY {
            word[0] = markedY
        }
        guard word.count > 1 else { return }
        for index in 1..<word.count
        where word[index] == lowercaseY
            && isVowel(word[index - 1]) {
            word[index] = markedY
        }
    }

    private static func firstRegion(
        in word: [UInt8],
        after start: Int
    ) -> Int {
        if start == 0 {
            let value = string(word)
            if value.hasPrefix("gener") { return 5 }
            if value.hasPrefix("commun") { return 6 }
            if value.hasPrefix("arsen") { return 5 }
        }
        guard word.count > 1, start < word.count - 1 else {
            return word.count
        }
        for index in max(1, start + 1)..<word.count
        where isVowel(word[index - 1])
            && !isVowel(word[index]) {
            return index + 1
        }
        return word.count
    }

    private static func step0(_ word: inout [UInt8]) {
        for suffix in ["'s'", "'s", "'"] where hasSuffix(word, suffix) {
            word.removeLast(suffix.utf8.count)
            return
        }
    }

    private static func step1a(_ word: inout [UInt8]) {
        if hasSuffix(word, "sses") {
            replaceSuffix(&word, "sses", with: "ss")
            return
        }
        for suffix in ["ied", "ies"] where hasSuffix(word, suffix) {
            let stemLength = word.count - suffix.utf8.count
            replaceSuffix(
                &word,
                suffix,
                with: stemLength > 1 ? "i" : "ie")
            return
        }
        if hasSuffix(word, "ss") || hasSuffix(word, "us") {
            return
        }
        if hasSuffix(word, "s"),
           word.count > 2,
           containsVowel(word.prefix(word.count - 2)) {
            word.removeLast()
        }
    }

    private static func step1b(
        _ word: inout [UInt8],
        r1: Int
    ) {
        for suffix in ["eedly", "eed"] where hasSuffix(word, suffix) {
            let suffixStart = word.count - suffix.utf8.count
            if suffixStart >= r1 {
                replaceSuffix(&word, suffix, with: "ee")
            }
            return
        }

        for suffix in ["ingly", "edly", "ing", "ed"]
        where hasSuffix(word, suffix) {
            let suffixStart = word.count - suffix.utf8.count
            guard containsVowel(word.prefix(suffixStart)) else {
                return
            }
            word.removeLast(suffix.utf8.count)
            if ["at", "bl", "iz"].contains(where: {
                hasSuffix(word, $0)
            }) {
                word.append(UInt8(ascii: "e"))
            } else if ["bb", "dd", "ff", "gg", "mm", "nn",
                       "pp", "rr", "tt"].contains(where: {
                           hasSuffix(word, $0)
                       }) {
                word.removeLast()
            } else if word.count == r1, isShortSyllable(word) {
                word.append(UInt8(ascii: "e"))
            }
            return
        }
    }

    private static func step1c(_ word: inout [UInt8]) {
        guard word.count > 2,
              word.last == lowercaseY || word.last == markedY,
              let preceding = word.dropLast().last,
              !isVowel(preceding) else {
            return
        }
        word[word.count - 1] = UInt8(ascii: "i")
    }

    private static func step2(
        _ word: inout [UInt8],
        r1: Int
    ) {
        let replacements: [(String, String)] = [
            ("ization", "ize"),
            ("ational", "ate"),
            ("fulness", "ful"),
            ("ousness", "ous"),
            ("iveness", "ive"),
            ("tional", "tion"),
            ("biliti", "ble"),
            ("lessli", "less"),
            ("entli", "ent"),
            ("ation", "ate"),
            ("alism", "al"),
            ("aliti", "al"),
            ("ousli", "ous"),
            ("iviti", "ive"),
            ("fulli", "ful"),
            ("enci", "ence"),
            ("anci", "ance"),
            ("abli", "able"),
            ("izer", "ize"),
            ("ator", "ate"),
            ("alli", "al"),
            ("bli", "ble"),
        ]
        for (suffix, replacement) in replacements
        where hasSuffix(word, suffix) {
            let start = word.count - suffix.utf8.count
            if start >= r1 {
                replaceSuffix(&word, suffix, with: replacement)
            }
            return
        }
        if hasSuffix(word, "ogi") {
            let start = word.count - 3
            if start >= r1,
               start > 0,
               word[start - 1] == UInt8(ascii: "l") {
                replaceSuffix(&word, "ogi", with: "og")
            }
            return
        }
        if hasSuffix(word, "li") {
            let start = word.count - 2
            let valid: Set<UInt8> = [
                UInt8(ascii: "c"), UInt8(ascii: "d"),
                UInt8(ascii: "e"), UInt8(ascii: "g"),
                UInt8(ascii: "h"), UInt8(ascii: "k"),
                UInt8(ascii: "m"), UInt8(ascii: "n"),
                UInt8(ascii: "r"), UInt8(ascii: "t"),
            ]
            if start >= r1,
               start > 0,
               valid.contains(word[start - 1]) {
                word.removeLast(2)
            }
        }
    }

    private static func step3(
        _ word: inout [UInt8],
        r1: Int,
        r2: Int
    ) {
        let replacements: [(String, String)] = [
            ("ational", "ate"),
            ("tional", "tion"),
            ("alize", "al"),
            ("icate", "ic"),
            ("iciti", "ic"),
            ("ical", "ic"),
            ("ful", ""),
            ("ness", ""),
        ]
        for (suffix, replacement) in replacements
        where hasSuffix(word, suffix) {
            let start = word.count - suffix.utf8.count
            if start >= r1 {
                replaceSuffix(&word, suffix, with: replacement)
            }
            return
        }
        if hasSuffix(word, "ative") {
            let start = word.count - 5
            if start >= r1, start >= r2 {
                word.removeLast(5)
            }
        }
    }

    private static func step4(
        _ word: inout [UInt8],
        r2: Int
    ) {
        let suffixes = [
            "ement", "ance", "ence", "able", "ible", "ment",
            "ant", "ent", "ism", "ate", "iti", "ous", "ive",
            "ize", "al", "er", "ic",
        ]
        for suffix in suffixes where hasSuffix(word, suffix) {
            let start = word.count - suffix.utf8.count
            if start >= r2 {
                word.removeLast(suffix.utf8.count)
            }
            return
        }
        if hasSuffix(word, "ion") {
            let start = word.count - 3
            if start >= r2,
               start > 0,
               (word[start - 1] == UInt8(ascii: "s")
                || word[start - 1] == UInt8(ascii: "t")) {
                word.removeLast(3)
            }
        }
    }

    private static func step5(
        _ word: inout [UInt8],
        r1: Int,
        r2: Int
    ) {
        if hasSuffix(word, "e") {
            let start = word.count - 1
            if start >= r2
                || (start >= r1
                    && !isShortSyllable(Array(word.dropLast()))) {
                word.removeLast()
            }
            return
        }
        if hasSuffix(word, "l") {
            let start = word.count - 1
            if start >= r2,
               start > 0,
               word[start - 1] == UInt8(ascii: "l") {
                word.removeLast()
            }
        }
    }

    private static func isShortSyllable(_ word: [UInt8]) -> Bool {
        if word.count >= 3 {
            let first = word[word.count - 3]
            let middle = word[word.count - 2]
            let last = word[word.count - 1]
            return !isVowel(first)
                && isVowel(middle)
                && !isVowel(last)
                && last != UInt8(ascii: "w")
                && last != UInt8(ascii: "x")
                && last != markedY
        }
        if word.count == 2 {
            return isVowel(word[0]) && !isVowel(word[1])
        }
        return false
    }

    private static func containsVowel<S: Sequence>(
        _ bytes: S
    ) -> Bool where S.Element == UInt8 {
        bytes.contains(where: isVowel)
    }

    private static func isVowel(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "a")
            || byte == UInt8(ascii: "e")
            || byte == UInt8(ascii: "i")
            || byte == UInt8(ascii: "o")
            || byte == UInt8(ascii: "u")
            || byte == lowercaseY
    }

    private static func hasSuffix(
        _ word: [UInt8],
        _ suffix: String
    ) -> Bool {
        word.suffix(suffix.utf8.count).elementsEqual(suffix.utf8)
    }

    private static func replaceSuffix(
        _ word: inout [UInt8],
        _ suffix: String,
        with replacement: String
    ) {
        word.removeLast(suffix.utf8.count)
        word.append(contentsOf: replacement.utf8)
    }

    private static func string(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
