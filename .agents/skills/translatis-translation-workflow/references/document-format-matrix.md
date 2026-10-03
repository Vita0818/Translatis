# Translatis Translation Format Matrix

This reference records the current Translatis exact tool surface. It is a routing aid, not a
permission grant and not a promise that every format has round-trip translation fidelity.

| Input | Read / continuation | Current write or export boundary |
|---|---|---|
| PDF | `inspect_pdf`, `read_pdf`, explicit `ocr_pdf`, `pdf_render_page` | No general PDF text rewrite; export only through supported source-format tools |
| DOCX | `read_docx`, `continue_docx_read` | Exact DOCX create/mutate tools; validate run/table/header/footer fidelity |
| PPTX | `read_pptx`, `continue_pptx_read` | Exact shape/table/slide tools; validate layouts, notes, and embedded content |
| XLSX | `read_xlsx`, `continue_xlsx_read` | Exact cell/sheet/row tools; do not interpret or recalculate formulas |
| HTML | `read_html`, `continue_html_read` | No generic HTML writer; PDF export is a separate exact operation |
| EPUB | `read_epub`, `continue_epub_read` | EPUB write is not part of the current production surface |

Always consult the current Translatis source and registry before relying on a tool name. The
authoritative model-facing catalog and the current lease/permission state outrank this table.
