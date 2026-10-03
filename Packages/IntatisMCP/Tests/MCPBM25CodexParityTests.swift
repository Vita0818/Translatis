#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCPTests requires CryptoKit or swift-crypto")
#endif
import Foundation
import XCTest
@testable import IntatisMCP

/// Golden values were generated directly with bm25 2.3.2 configured exactly
/// as pinned Codex does:
/// `SearchEngineBuilder::<usize>::with_documents(Language::English, docs)`.
final class MCPBM25CodexParityTests: XCTestCase {
    func testVendoredDeunicode162TablesAreByteExact() {
        XCTAssertEqual(
            MCPDeunicode162Data.mappingBytes.count,
            56_405)
        XCTAssertEqual(
            sha256(MCPDeunicode162Data.mappingBytes),
            "8cb5a957e0bf7b702accc3ba25bf01bb34c1b0cc5d5fa4f0081d36c2cb63db20")
        XCTAssertEqual(
            MCPDeunicode162Data.pointerBytes.count,
            419_994)
        XCTAssertEqual(
            sha256(MCPDeunicode162Data.pointerBytes),
            "f2e1772f608f050555f6bd0f1d7a2b453b929bd02300927ce2db6afb88ad500f")
    }

    func testNLTKEnglishStopWordSetIsComplete() {
        XCTAssertEqual(MCPEnglishTokenizer.stopWords.count, 179)
        for word in MCPEnglishTokenizer.stopWords {
            XCTAssertTrue(
                MCPEnglishTokenizer.tokens(word).isEmpty,
                "expected pinned stop word to be removed: \(word)")
        }
    }

    func testTokenizerGoldenCorpusFromPinnedBM25232() {
        let corpus: [(String, [String])] = [
            (
                "The runners were running relationally.",
                ["runner", "run", "relat"]),
            (
                "you're we've don't canning skies dying only",
                ["we'v", "canning", "sky", "die"]),
            (
                "calendar_events get_weather",
                ["calendar_ev", "get_weath"]),
            (
                "Café Æneid 北亰 🦄🍕☣",
                [
                    "cafe", "aeneid", "bei", "jing",
                    "unicorn", "pizza", "biohazard",
                ]),
            (
                "can't won't foo-bar foo_bar 3.14 C++",
                ["can't", "foo", "bar", "foo_bar", "3.14", "c"]),
            (
                "generously communism arsenic",
                ["generous", "communism", "arsenic"]),
            (
                "_foo foo_ __ foo__bar 1,000 1:2 a:b a.b",
                [
                    "_foo", "foo_", "foo__bar", "1,000",
                    "1", "2", "a:b", "a.b",
                ]),
            (
                "O'Reilly rock'n'roll l'amour 'quoted' foo..bar 1..2",
                [
                    "o'reilli", "rock'n'rol", "l'amour", "quot",
                    "foo", "bar", "1", "2",
                ]),
        ]
        for (input, expected) in corpus {
            XCTAssertEqual(
                MCPEnglishTokenizer.tokens(input),
                expected,
                input)
        }
    }

    func testASCIIUnicodeWordBoundaryDifferentialCorpus() {
        let alphabet = [
            "a", "b", "1", "2", "_", "'", ".",
            ":", ",", ";", "+", "-",
        ]
        var digest = SHA256()
        for length in 1...4 {
            enumerateStrings(
                alphabet: alphabet,
                length: length) { value in
                    let line = MCPEnglishTokenizer.tokens(value)
                        .joined(separator: "\u{001F}") + "\n"
                    digest.update(data: Data(line.utf8))
                }
        }
        XCTAssertEqual(
            hex(digest.finalize()),
            "dc0f9c7b7507cea5bf2298e47561dfe297777f464708da0fe2ea9b8717544f19")
    }

    func testSnowballEnglishGeneratedDifferentialCorpus() {
        let roots = [
            "consign", "commun", "gener", "arsen", "hope", "rate",
            "relate", "condition", "formal", "electric", "revival",
            "probate", "cease", "control", "roll", "sky", "die",
            "lie", "tie", "ugly", "early", "only", "single",
            "proceed", "canning",
        ]
        let suffixes = [
            "", "s", "sses", "ied", "ies", "eed", "eedly", "ed",
            "edly", "ing", "ingly", "y", "ational", "tional",
            "enci", "anci", "abli", "entli", "izer", "ization",
            "ation", "ator", "alism", "aliti", "alli", "fulness",
            "ousli", "ousness", "iveness", "iviti", "biliti", "bli",
            "fulli", "lessli", "ogi", "li", "icate", "ative",
            "alize", "iciti", "ical", "ful", "ness", "ance", "ence",
            "able", "ible", "ment", "ement", "ant", "ent", "ism",
            "ate", "iti", "ous", "ive", "ize", "ion", "er", "ic",
            "e", "l",
        ]
        var digest = SHA256()
        for root in roots {
            for suffix in suffixes {
                let stem =
                    MCPEnglishSnowballStemmer.stem(root + suffix)
                digest.update(data: Data((stem + "\n").utf8))
            }
        }
        XCTAssertEqual(
            hex(digest.finalize()),
            "a876375f69ea0d7d7e8e60030760907b000652a4b39592d8fcf28ccbb1c68ead")
    }

    func testFxHash32MatchesPinnedBM25TokenEmbedder() {
        XCTAssertEqual(MCPFxHash32.hash("runner"), 2_367_581_277)
        XCTAssertEqual(MCPFxHash32.hash("calendar_ev"), 301_194_235)
        XCTAssertEqual(MCPFxHash32.hash("can't"), 2_937_562_076)
        XCTAssertEqual(MCPFxHash32.hash("cafe"), 1_614_138_486)
    }

    func testBM25GoldenScoresAreBitExact() {
        let index = MCPBM25Index(documents: [
            "calendar event events scheduling scheduled",
            "weather forecast forecasts temperature",
            "calendar weather integration",
            "send email message messages",
            "running runner relational conditional",
            "Café Æneid 北亰 unicorn pizza biohazard",
        ])
        assertResults(
            index.search(query: "calendar event", limit: 20),
            [(0, 0x4042_7B5F), (2, 0x3F98_99B6)])
        assertResults(
            index.search(query: "weather weather", limit: 20),
            [(2, 0x4018_99B6), (1, 0x400A_112C)])
        assertResults(
            index.search(query: "run relation", limit: 20),
            [(4, 0x404E_90FD)])
        assertResults(
            index.search(query: "cafe 北亰 🦄", limit: 20),
            [(5, 0x40A0_A9A7)])
        XCTAssertTrue(
            index.search(query: "the and is", limit: 20).isEmpty)
    }

    func testLargeTokenTotalAverageUsesPinnedF64ThenF32Order() {
        // 2^24 + 1 cannot be represented exactly as Float. A premature f32
        // cast would produce bit pattern 0x4a4ccccd instead.
        XCTAssertEqual(
            MCPBM25Index.averageDocumentLength(
                totalLength: 16_777_217,
                documentCount: 5).bitPattern,
            0x4A4C_CCCE)
    }

    func testBM25WideDifferentialCorpusIsBitExact() {
        let topics = [
            "calendar scheduling event attendee",
            "weather forecast temperature climate",
            "email message delivery inbox",
            "repository source code branch",
            "database query record analytics",
            "invoice payment accounting ledger",
            "Café Æneid 北亰 🦄 pizza",
            "running relational conditional skies",
        ]
        let queryTopics = [
            "calendar event",
            "weather weather temperature",
            "email delivery",
            "repository branch",
            "database analytics",
            "invoice ledger",
            "cafe 北亰 unicorn",
            "run relation sky",
        ]
        let documents = (0..<512).map { index in
            "document_\(index) \(topics[index % topics.count]) common common marker_\(index % 31)"
        }
        let index = MCPBM25Index(documents: documents)
        var digest = SHA256()
        for queryIndex in 0..<128 {
            let query =
                "\(queryTopics[queryIndex % queryTopics.count]) marker_\(queryIndex % 31)"
            let matches = index.search(
                query: query,
                limit: documents.count).sorted {
                    $0.index < $1.index
                }
            var line = "\(queryIndex)"
            for match in matches {
                let bits = Float(match.score).bitPattern
                line += String(
                    format: "\t%d:%08x",
                    match.index,
                    bits)
            }
            digest.update(data: Data((line + "\n").utf8))
        }
        XCTAssertEqual(
            hex(digest.finalize()),
            "983ecb3965370058ad7bcb405606a8364b1a15648d7c70258cf5db086cd0a06f")
    }

    func testTenThousandDocumentStressCorpus() {
        let documents = (0..<10_000).map { index in
            "tool_\(index) common metadata unique_marker_\(index)"
        }
        let index = MCPBM25Index(documents: documents)
        let matches = index.search(
            query: "unique_marker_9999",
            limit: MCPToolSearchConstants.defaultLimit)
        XCTAssertFalse(matches.isEmpty)
        XCTAssertLessThanOrEqual(
            matches.count,
            MCPToolSearchConstants.defaultLimit)
        XCTAssertTrue(matches.contains(where: { $0.index == 9_999 }))
        XCTAssertTrue(matches.allSatisfy {
            $0.index >= 0
                && $0.index < documents.count
                && $0.score.isFinite
                && $0.score > 0
        })
        XCTAssertEqual(
            matches,
            index.search(
                query: "unique_marker_9999",
                limit: MCPToolSearchConstants.defaultLimit))
    }
}

private func assertResults(
    _ actual: [MCPBM25Index.Ranked],
    _ expected: [(Int, UInt32)],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        actual.map(\.index),
        expected.map(\.0),
        file: file,
        line: line)
    XCTAssertEqual(
        actual.map { Float($0.score).bitPattern },
        expected.map(\.1),
        file: file,
        line: line)
}

private func enumerateStrings(
    alphabet: [String],
    length: Int,
    prefix: String = "",
    body: (String) -> Void
) {
    guard length > 0 else {
        body(prefix)
        return
    }
    for symbol in alphabet {
        enumerateStrings(
            alphabet: alphabet,
            length: length - 1,
            prefix: prefix + symbol,
            body: body)
    }
}

private func sha256(_ bytes: [UInt8]) -> String {
    hex(SHA256.hash(data: Data(bytes)))
}

private func hex<D: Sequence>(_ digest: D) -> String
where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}
