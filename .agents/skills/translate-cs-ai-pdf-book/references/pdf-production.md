# PDF Production

Read this reference before producing chapter or full-book PDFs.

## Source inspection

Use PDF-aware tools rather than trusting a single text export:

- inspect metadata, encryption, page count, dimensions, rotation, forms, and text presence;
- extract text both normally and with layout preservation;
- render pages with Poppler and inspect representative single-column, multi-column, formula-heavy, code-heavy, figure-heavy, and back-matter pages;
- enumerate embedded images only when needed for faithful reuse;
- distinguish physical PDF indices from printed page labels.

Create a coverage table before translation. Include all front matter, unnumbered pages, roman-numbered pages, chapter ranges, formal corrections, appendices, references, and index pages.

## Artifact organization

Keep source material, generated intermediates, and formal outputs separate. A useful shape is:

```text
tmp/pdfs/<book>/
  source/
  assets/
  chapter-01/
  rendered/
  validation/
output/pdf/
  <book>_zh-CN_front_matter.pdf
  <book>_zh-CN_ch01.pdf
  <book>_zh-CN_appendix_A.pdf
  <book>_zh-CN_references_and_index.pdf
  <book>_zh-CN_complete.pdf
```

Use names appropriate to the book; the structure is guidance, not a required literal convention. Keep pilot files visibly separate from formal outputs.

## Typesetting

- Match the source page size unless the user requests a redesign.
- Prefer a robust Unicode workflow such as XeLaTeX when equations and CJK typography are substantial. Use the available LaTeX compilation skill when present.
- Embed CJK, Latin, monospace, and mathematics fonts. Verify Unicode mappings after compilation.
- Preserve hierarchy, whitespace, reading order, page headers/footers, figure/table captions, and original printed page numbers.
- Use actual text and vector primitives for prose, formulas, tables, and semantic diagrams. Raster images are appropriate for photographs and complex source imagery.
- Keep links clickable. Preserve DOI, license, source, and relevant internal navigation links.
- Add PDF metadata, language, outlines/bookmarks, and page labels.

## Page labels and covers

Original printed page labels are part of the scholarly navigation system. Preserve roman numerals, numeric ranges, correction labels such as C1/C3, and intentionally skipped printed numbers.

If adding section covers:

- give each cover a unique label such as `第3章封面` or `附录B封面`;
- begin the translated source pages at their original printed label;
- do not count added covers as translated source pages;
- keep a formula for coverage, for example: `assembled pages = source physical pages + added navigation pages`.

## Figures, assets, and fidelity

- Inspect an original image before editing or reusing it.
- Recreate semantic diagrams in vector form and translate their labels.
- Preserve source photographs/plots at adequate resolution and retain credits.
- Never stretch images disproportionately or crop away meaningful content.
- Check color contrast and legibility at normal reading zoom, not only at source resolution.

## Merging

Assemble formal components in source order. Preserve or reconstruct:

- page content and text extraction;
- URI and internal link annotations;
- metadata and document language;
- hierarchical bookmarks;
- page labels;
- uniform media boxes and rotation.

After merging, compare the complete edition against components page by page. At minimum confirm text identity, annotation counts, page count, dimensions, and boundary order. Treat library warnings about link remapping as actionable until annotation totals and targets are verified.
