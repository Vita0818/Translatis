# Translation Policy

Read this reference before translating any book content. Apply the user's explicit terminology or editorial choices over these defaults.

## Semantic translation

- Translate the proposition the author is making, not the English word sequence. Preserve logical relationships, conditions, exceptions, emphasis, uncertainty, and distinctions between definitions, claims, heuristics, and examples.
- Use idiomatic Chinese technical prose. Recast long English sentences when needed, but do not compress them into summaries or add unsupported explanations.
- Resolve pronouns, ellipsis, and overloaded terminology from surrounding paragraphs, formulas, figures, and earlier definitions.
- Preserve pedagogical tone, including jokes, cautions, and informal intuition, when they carry meaning.
- If extraction has broken columns, symbols, superscripts, subscripts, or sentence order, treat the rendered page as authoritative for reconstruction.

## Terminology decisions

Maintain a glossary with at least: source term, preferred Chinese term, first occurrence, retained acronym, domain/context, and exceptions.

Use this decision order:

1. Use a mature, unambiguous Chinese technical term when one exists: machine learning → 机器学习; gradient descent → 梯度下降; Markov chain → 马尔可夫链.
2. At first occurrence, introduce a useful English name or acronym as `中文名称（English term，ACRONYM）`; later use the shortest unambiguous form.
3. Preserve established product, library, protocol, model, format, and algorithm names when translation would reduce precision: Python, PyTorch, CUDA, HTTP, Transformer, BERT, GPT.
4. Preserve mathematical identifiers, program identifiers, API members, file paths, configuration keys, command flags, and formal syntax.
5. Preserve personal names unless a standard Chinese form is genuinely useful; retain the original name at first occurrence when transliterating.
6. When a term has competing translations, choose by local technical meaning and remain consistent. Do not alternate merely for stylistic variety.

Do not leave whole sentences untranslated merely because they contain technical names.

## Mathematics and formal statements

- Preserve equation, definition, theorem, lemma, example, algorithm, figure, table, and exercise numbering.
- Verify signs, parentheses, quantifiers, domains, conditions, indices, limits, dimensions, vector/matrix styling, transposes, norms, integral bounds, summation ranges, and probability conditioning.
- Keep mathematical notation unchanged unless the source is demonstrably wrong or inconsistent with its own declared convention.
- Do not turn formulas into images. Re-typeset them with a searchable mathematical text layer.
- Translate proof structure and explanatory text completely; retain QED markers and dependencies on prior results.

## Code, pseudocode, and commands

- Keep code executable. Do not translate language keywords, identifiers, imports, module names, API calls, string constants that affect behavior, shell commands, file paths, or configuration keys.
- Translate pedagogical comments when doing so does not alter syntax or behavior.
- Translate natural-language pseudocode controls such as Input, Output, Initialize, Repeat, If, Else, and Return; retain mathematical and program identifiers.
- Preserve indentation, line numbering, monospace styling, and references from prose to code.
- For user-facing strings, translate only when the book is explaining interface text rather than relying on the exact literal value.

## Figures and tables

- Translate captions, legends, axes, units, labels, callouts, and surrounding discussion.
- Redraw diagrams as vectors when they are primarily semantic structure: block diagrams, flowcharts, state diagrams, graphs, timelines, coordinate sketches, and network diagrams.
- Reuse photographs, screenshots, scientific plots, and complex source illustrations when redrawing would reduce fidelity; add translated captions and preserve credits.
- Rebuild tables as actual text/table structures. Preserve row/column relationships, units, footnotes, and alignment of numeric values.

## Source errors and editorial intervention

Correct only errors that are objectively verifiable from mathematics, code execution, a cited definition, or an unambiguous internal contradiction.

When correcting:

- use the correct content in the translation;
- add a concise `译校` note stating the source form, why it fails, and the corrected result;
- distinguish exact correction from engineering approximation or editorial preference;
- do not claim an error when the issue is merely ambiguous notation or an alternative convention.

If confidence is insufficient, preserve the source and flag the ambiguity without inventing a resolution.

## References, index, and rights

- Keep bibliographic authors, work titles, journal/conference names, publishers, DOI, ISBN, arXiv identifiers, and URLs in their original searchable form. Translate connective metadata such as edition, volume, issue, pages, and “in/edited by” when helpful.
- Translate index concepts using the book's glossary while retaining useful acronyms, eponyms, and the original alphabetical grouping. Preserve the source printed-page references.
- Preserve copyright, author attribution, edition, publisher, license, third-party-material credits, correction notices, and modification requirements.
- Clearly identify the result as a Chinese translation and typeset adaptation. Never imply authorization beyond the source license or the user's rights.
