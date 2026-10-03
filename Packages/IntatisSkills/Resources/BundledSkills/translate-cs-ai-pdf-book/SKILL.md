---
name: translate-cs-ai-pdf-book
description: Translate complete text-bearing CS, AI, ML, data-science, EE, or mathematical textbooks from English PDFs into high-quality searchable Simplified Chinese PDFs. Use for book-length technical translation that requires terminology judgment, formula/code/figure preservation, per-page coverage, chapter editions, and verified full-book assembly; not for short excerpts or OCR-first image-only scans unless the user explicitly accepts an OCR workflow.
---

# Translate CS/AI PDF Books

Produce a complete Chinese technical edition, not a summary or a mechanically substituted text dump. Treat translation, technical review, typesetting, and PDF verification as one continuous job.

## Non-negotiable invariants

- Read and understand every source page. Use extracted text for navigation, but use rendered pages to recover reading order, equations, figures, tables, footnotes, and typography.
- Do not call external translation services or use keyword-replacement, glossary-substitution, or bulk machine-translation scripts. Scripts may perform mechanical extraction, rendering, compilation, merging, labeling, and validation only.
- Translate semantically into natural Simplified Chinese while preserving the source's technical claims, argument structure, qualifications, and tone.
- Do not omit front matter, body text, proofs, examples, captions, tables, code, exercises, appendices, formal corrections, references, index entries, license text, or other substantive content.
- Preserve mathematical meaning, identifiers, numbering, code behavior, citations, and cross-references. Never silently repair a source error: use an explicit translator/editor note when a correction is objectively verifiable.
- Deliver searchable PDFs with real Chinese text layers. Do not rasterize whole pages as the final artifact.
- Once the user approves a pilot or says to continue, proceed through the remaining book without asking for routine chapter-by-chapter confirmation. Stop only for a material ambiguity that would change scope, rights, language, or editorial policy.

## Load the relevant guidance

- Before translating prose, terminology, mathematics, code, references, or an index, read [references/translation-policy.md](references/translation-policy.md).
- Before creating chapter PDFs or a full-book edition, read [references/pdf-production.md](references/pdf-production.md).
- Before declaring a chapter or book complete, read and apply [references/qa-checklist.md](references/qa-checklist.md).

## Workflow

1. **Preflight the source.** Locate the PDF, inspect metadata, page count, page size, text-layer quality, links, bookmarks, license, and whether pages are single-column, multi-column, or image-heavy. Render representative pages. If the source is effectively image-only, disclose that this skill's normal text-bearing workflow does not apply and obtain direction before adopting OCR.
2. **Build a coverage map.** Map every physical PDF page to front matter, chapters, corrections, appendices, references, and index. Record printed-page labels separately from physical page indices; skipped printed numbers are not missing pages.
3. **Choose pilot or continuous mode.** If the user requests a sample, choose a representative complete section containing prose plus formulas, figures, tables, or code. Apply final-quality terminology and layout to the pilot. Otherwise begin the full book directly.
4. **Establish terminology.** Maintain a living glossary of preferred Chinese terms, preserved English names, acronyms, and context-dependent exceptions. Reuse earlier decisions throughout the book.
5. **Translate page by page.** Compare extracted text with rendered pages, reconstruct broken formulas and reading order, translate all natural-language content, and retain a source-page-to-output-page trace.
6. **Typeset by coherent units.** Produce front matter, chapters, corrections, appendices, and back matter as independently readable PDFs. Preserve original printed page labels; added navigation covers receive distinct labels and do not count as translated source pages.
7. **Validate each unit.** Compile cleanly, render every page, inspect dense or unusual pages at full detail, and run structural checks before moving on.
8. **Assemble the complete edition.** Merge only formal components, import or reconstruct bookmarks, preserve links and metadata, and verify that every source physical page appears exactly once. Keep pilot artifacts out of the formal edition.
9. **Report evidence.** Provide clickable paths to the complete PDF and components, coverage counts, validation results, file size, and SHA-256. Briefly summarize terminology and any explicit editorial corrections.

## Completion standard

A book is complete only when all source physical pages are accounted for, all formal output pages have searchable text, chapter and full-book PDFs pass structural and visual checks, bookmarks/page labels are correct, fonts are embedded, and the assembled edition preserves component text and links.
