# Quality Checklist

Read and apply this checklist before declaring a chapter or complete book finished.

## Per-page editorial check

- Every source page has a mapped output page.
- All prose, headings, captions, footnotes, callouts, table cells, and exercise text are translated.
- Formula structure and numbering match the source; no broken extraction artifacts remain.
- Code and commands retain executable syntax and exact identifiers.
- Figure/table references point to the correct objects.
- Terminology agrees with the glossary and earlier chapters.
- Any objective correction has an explicit translator/editor note.
- No page is cropped, overlapped, unexpectedly blank, unreadably dense, or missing its text layer.

Render every output page. Contact sheets are useful for global rhythm and omissions, but inspect formula-heavy, code-heavy, image-heavy, dense, and suspicious pages at original detail.

## Structural checks for every formal PDF

- strict parser opens it successfully;
- expected page count and page size;
- no encrypted output unless requested;
- no empty extracted-text pages, except intentional image-only pages documented in the report;
- all CJK, Latin, monospace, and math fonts embedded with usable Unicode mapping;
- no compile warnings, overfull/underfull boxes, missing glyphs, undefined references, or unreplaced placeholders;
- bookmarks and page labels resolve correctly;
- URI and internal link annotations remain present;
- metadata title, author, subject, and language are correct;
- a full rendering/parser pass completes without error.

Useful tools when available include `pdfinfo`, `pdffonts`, `pdftotext`, `pdftoppm`, Ghostscript's `nullpage` device, and the bundled [audit_pdf.py](../scripts/audit_pdf.py). Tool success does not replace visual inspection.

## Full-book coverage audit

Before assembly, inventory formal components and exclude pilots. Compute:

- number of source physical pages;
- translated source pages represented by each component;
- number of added navigation covers;
- expected assembled page count.

After assembly verify:

- assembled page count equals the coverage calculation;
- first/last labels and every component boundary label are correct;
- all component text appears in the same order;
- link/annotation totals match the components;
- all source physical pages occur exactly once;
- bookmark hierarchy covers front matter, chapters, corrections, appendices, references, and index;
- first page, last page, and every component boundary render correctly.

## Final handoff

Report:

- complete PDF path and component directory;
- source coverage and final page count;
- whether full text is searchable;
- page-label, bookmark, link, and embedded-font results;
- visual and parser validation outcome;
- file size and SHA-256;
- concise list of substantive translator/editor corrections;
- any documented limitation that remains.
