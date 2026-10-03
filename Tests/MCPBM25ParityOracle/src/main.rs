use bm25::{DefaultTokenizer, Document, Language, SearchEngineBuilder, Tokenizer};
use rust_stemmers::{Algorithm, Stemmer};
use std::env;

const ASCII_ALPHABET: &[u8] = b"ab12_'.:,;+-";

const STEM_ROOTS: &[&str] = &[
    "consign",
    "commun",
    "gener",
    "arsen",
    "hope",
    "rate",
    "relate",
    "condition",
    "formal",
    "electric",
    "revival",
    "probate",
    "cease",
    "control",
    "roll",
    "sky",
    "die",
    "lie",
    "tie",
    "ugly",
    "early",
    "only",
    "single",
    "proceed",
    "canning",
];

const STEM_SUFFIXES: &[&str] = &[
    "", "s", "sses", "ied", "ies", "eed", "eedly", "ed", "edly", "ing", "ingly", "y", "ational",
    "tional", "enci", "anci", "abli", "entli", "izer", "ization", "ation", "ator", "alism",
    "aliti", "alli", "fulness", "ousli", "ousness", "iveness", "iviti", "biliti", "bli", "fulli",
    "lessli", "ogi", "li", "icate", "ative", "alize", "iciti", "ical", "ful", "ness", "ance",
    "ence", "able", "ible", "ment", "ement", "ant", "ent", "ism", "ate", "iti", "ous", "ive",
    "ize", "ion", "er", "ic", "e", "l",
];

const DOCUMENT_TOPICS: &[&str] = &[
    "calendar scheduling event attendee",
    "weather forecast temperature climate",
    "email message delivery inbox",
    "repository source code branch",
    "database query record analytics",
    "invoice payment accounting ledger",
    "Café Æneid 北亰 🦄 pizza",
    "running relational conditional skies",
];

const QUERY_TOPICS: &[&str] = &[
    "calendar event",
    "weather weather temperature",
    "email delivery",
    "repository branch",
    "database analytics",
    "invoice ledger",
    "cafe 北亰 unicorn",
    "run relation sky",
];

fn main() {
    match env::args().nth(1).as_deref() {
        Some("ascii-tokenizer") => ascii_tokenizer(),
        Some("stemmer") => stemmer(),
        Some("wide-bm25") => wide_bm25(),
        Some("golden") => golden(),
        _ => {
            eprintln!(
                "usage: cargo run --release -- \
                 <ascii-tokenizer|stemmer|wide-bm25|golden>"
            );
            std::process::exit(2);
        }
    }
}

fn ascii_tokenizer() {
    let tokenizer = DefaultTokenizer::new(Language::English);
    for length in 1..=4 {
        let mut value = vec![0_u8; length];
        emit_ascii_words(&tokenizer, &mut value, 0);
    }
}

fn emit_ascii_words(tokenizer: &DefaultTokenizer, value: &mut [u8], index: usize) {
    if index == value.len() {
        let value = std::str::from_utf8(value).expect("ASCII fixture");
        println!("{}", tokenizer.tokenize(value).join("\u{1f}"));
        return;
    }
    for byte in ASCII_ALPHABET {
        value[index] = *byte;
        emit_ascii_words(tokenizer, value, index + 1);
    }
}

fn stemmer() {
    let stemmer = Stemmer::create(Algorithm::English);
    for root in STEM_ROOTS {
        for suffix in STEM_SUFFIXES {
            println!("{}", stemmer.stem(&format!("{root}{suffix}")));
        }
    }
}

fn document(index: usize) -> String {
    format!(
        "document_{index} {} common common marker_{}",
        DOCUMENT_TOPICS[index % DOCUMENT_TOPICS.len()],
        index % 31,
    )
}

fn query(index: usize) -> String {
    format!(
        "{} marker_{}",
        QUERY_TOPICS[index % QUERY_TOPICS.len()],
        index % 31,
    )
}

fn wide_bm25() {
    let documents = (0..512)
        .map(|index| Document::new(index, document(index)))
        .collect::<Vec<_>>();
    let engine = SearchEngineBuilder::<usize>::with_documents(Language::English, documents).build();
    for index in 0..128 {
        let mut result = engine.search(&query(index), None);
        result.sort_by_key(|match_| match_.document.id);
        print!("{index}");
        for match_ in result {
            print!("\t{}:{:08x}", match_.document.id, match_.score.to_bits(),);
        }
        println!();
    }
}

fn golden() {
    let documents = vec![
        Document::new(0usize, "calendar event events scheduling scheduled"),
        Document::new(1usize, "weather forecast forecasts temperature"),
        Document::new(2usize, "calendar weather integration"),
        Document::new(3usize, "send email message messages"),
        Document::new(4usize, "running runner relational conditional"),
        Document::new(5usize, "Café Æneid 北亰 unicorn pizza biohazard"),
    ];
    let engine = SearchEngineBuilder::<usize>::with_documents(Language::English, documents).build();
    for query in [
        "calendar event",
        "weather weather",
        "run relation",
        "cafe 北亰 🦄",
        "the and is",
    ] {
        let mut result = engine.search(query, None);
        result.sort_by_key(|match_| match_.document.id);
        print!("{query}");
        for match_ in result {
            print!("\t{}:{:08x}", match_.document.id, match_.score.to_bits(),);
        }
        println!();
    }
}
