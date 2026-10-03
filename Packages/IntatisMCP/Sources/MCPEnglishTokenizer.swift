// Derived tokenizer for bm25 2.3.2's English DefaultTokenizer.
//
// It embeds the unmodified NLTK English list from stop-words 0.9.0, consumes
// the vendored deunicode 1.6.2 tables, and implements only the ASCII-observable
// UAX #29 behavior after transliteration. Provenance and license notices:
// ThirdPartyNotices/MCPToolSearch.md.

import Foundation

/// Exact default-tokenizer pipeline selected by
/// `bm25 2.3.2 DefaultTokenizer::new(Language::English)`:
/// deunicode 1.6.2 normalization, lowercase, Unicode word boundaries,
/// NLTK English stop words from stop-words 0.9.0, then the English Snowball
/// algorithm from rust-stemmers 1.2.0.
enum MCPEnglishTokenizer {
    static func tokens(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        let normalized = MCPDeunicode162.normalize(value).lowercased()
        return MCPASCIIUnicodeWords.words(normalized).compactMap { word in
            guard !stopWords.contains(word) else { return nil }
            return MCPEnglishSnowballStemmer.stem(word)
        }
    }

    /// Unmodified NLTK English list embedded by stop-words 0.9.0.
    static let stopWords = Set(
        """
        i
        me
        my
        myself
        we
        our
        ours
        ourselves
        you
        you're
        you've
        you'll
        you'd
        your
        yours
        yourself
        yourselves
        he
        him
        his
        himself
        she
        she's
        her
        hers
        herself
        it
        it's
        its
        itself
        they
        them
        their
        theirs
        themselves
        what
        which
        who
        whom
        this
        that
        that'll
        these
        those
        am
        is
        are
        was
        were
        be
        been
        being
        have
        has
        had
        having
        do
        does
        did
        doing
        a
        an
        the
        and
        but
        if
        or
        because
        as
        until
        while
        of
        at
        by
        for
        with
        about
        against
        between
        into
        through
        during
        before
        after
        above
        below
        to
        from
        up
        down
        in
        out
        on
        off
        over
        under
        again
        further
        then
        once
        here
        there
        when
        where
        why
        how
        all
        any
        both
        each
        few
        more
        most
        other
        some
        such
        no
        nor
        not
        only
        own
        same
        so
        than
        too
        very
        s
        t
        can
        will
        just
        don
        don't
        should
        should've
        now
        d
        ll
        m
        o
        re
        ve
        y
        ain
        aren
        aren't
        couldn
        couldn't
        didn
        didn't
        doesn
        doesn't
        hadn
        hadn't
        hasn
        hasn't
        haven
        haven't
        isn
        isn't
        ma
        mightn
        mightn't
        mustn
        mustn't
        needn
        needn't
        shan
        shan't
        shouldn
        shouldn't
        wasn
        wasn't
        weren
        weren't
        won
        won't
        wouldn
        wouldn't
        """
        .split(separator: "\n")
        .map(String.init))
}

/// `deunicode_with_tofu_cow(text, "[?]")` using the exact mapping and pointer
/// tables shipped by deunicode 1.6.2.
enum MCPDeunicode162 {
    static func normalize(_ value: String) -> String {
        if value.utf8.allSatisfy({ $0 < 0x7F }) {
            return value
        }
        let scalars = value.unicodeScalars.map { Int($0.value) }
        let mapped = scalars.map(mapping)
        var output: [UInt8] = []
        output.reserveCapacity(value.utf8.count | 15)
        for index in mapped.indices {
            guard let bytes = mapped[index] else {
                output.append(contentsOf: "[?]".utf8)
                continue
            }
            var end = bytes.endIndex
            if bytes.count > 1,
               bytes.last == UInt8(ascii: " "),
               index == mapped.index(before: mapped.endIndex)
                || mapped[index + 1]?.first == UInt8(ascii: " ") {
                end = bytes.index(before: end)
            }
            output.append(contentsOf: bytes[..<end])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func mapping(
        _ scalar: Int
    ) -> ArraySlice<UInt8>? {
        let pointerIndex = scalar.multipliedReportingOverflow(by: 3)
        guard !pointerIndex.overflow else { return nil }
        let start = pointerIndex.partialValue
        let pointers = MCPDeunicode162Data.pointerBytes
        guard start >= 0, start + 2 < pointers.count else {
            return nil
        }
        let first = pointers[start]
        let second = pointers[start + 1]
        let length = Int(pointers[start + 2])
        if length <= 2 {
            return pointers[start..<(start + length)]
        }
        let mappingStart = Int(first) | (Int(second) << 8)
        let mappingEnd =
            mappingStart.addingReportingOverflow(length)
        guard !mappingEnd.overflow,
              mappingStart >= 0,
              mappingEnd.partialValue
                <= MCPDeunicode162Data.mappingBytes.count else {
            return nil
        }
        return MCPDeunicode162Data.mappingBytes[
            mappingStart..<mappingEnd.partialValue]
    }
}

/// The default tokenizer normalizes to ASCII before calling
/// unicode-segmentation's `unicode_words`. These are the UAX #29 word rules
/// that remain observable for ASCII: letters/numbers, ExtendNumLet (`_`), and
/// the single internal MidLetter/MidNum/MidNumLet connectors.
private enum MCPASCIIUnicodeWords {
    static func words(_ value: String) -> [String] {
        let bytes = Array(value.utf8)
        var result: [String] = []
        var current: [UInt8] = []
        var containsAlphanumeric = false

        func finish() {
            if containsAlphanumeric {
                result.append(String(decoding: current, as: UTF8.self))
            }
            current.removeAll(keepingCapacity: true)
            containsAlphanumeric = false
        }

        for index in bytes.indices {
            let byte = bytes[index]
            if isAlphanumeric(byte) {
                current.append(byte)
                containsAlphanumeric = true
                continue
            }
            if byte == UInt8(ascii: "_") {
                current.append(byte)
                continue
            }
            if isConnector(byte),
               let previous = current.last,
               isAlphanumeric(previous),
               index + 1 < bytes.count,
               isAlphanumeric(bytes[index + 1]),
               connector(
                   byte,
                   joins: previous,
                   and: bytes[index + 1]) {
                current.append(byte)
                continue
            }
            finish()
        }
        finish()
        return result
    }

    private static func connector(
        _ connector: UInt8,
        joins previous: UInt8,
        and next: UInt8
    ) -> Bool {
        if connector == UInt8(ascii: ":") {
            return isLetter(previous) && isLetter(next)
        }
        if connector == UInt8(ascii: ",")
            || connector == UInt8(ascii: ";") {
            return isDigit(previous) && isDigit(next)
        }
        return (isLetter(previous) && isLetter(next))
            || (isDigit(previous) && isDigit(next))
    }

    private static func isConnector(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "'")
            || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: ":")
            || byte == UInt8(ascii: ",")
            || byte == UInt8(ascii: ";")
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isLetter(byte) || isDigit(byte)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
