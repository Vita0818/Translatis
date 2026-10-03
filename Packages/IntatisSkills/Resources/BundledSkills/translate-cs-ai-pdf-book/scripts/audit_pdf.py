#!/usr/bin/env python3
"""Read-only structural audit for one or more translated textbook PDFs."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any

from pypdf import PdfReader


def count_outline(items: list[Any]) -> int:
    return sum(count_outline(item) if isinstance(item, list) else 1 for item in items)


def annotation_kind(annotation: Any) -> str:
    obj = annotation.get_object()
    subtype = str(obj.get("/Subtype", "none"))
    action = obj.get("/A")
    action_type = str(action.get("/S", "none")) if action else "none"
    return f"{subtype}:{action_type}"


def audit(path: Path) -> dict[str, Any]:
    result: dict[str, Any] = {"path": str(path.resolve()), "ok": False}
    try:
        reader = PdfReader(str(path), strict=True)
        text_lengths = [len((page.extract_text() or "").strip()) for page in reader.pages]
        size_tuples = sorted(
            {
                (round(float(page.mediabox.width), 2), round(float(page.mediabox.height), 2))
                for page in reader.pages
            }
        )
        sizes = [list(size) for size in size_tuples]
        annotations: Counter[str] = Counter()
        for page in reader.pages:
            refs = page.get("/Annots")
            if refs:
                annotations.update(annotation_kind(ref) for ref in refs.get_object())

        labels = reader.page_labels
        result.update(
            {
                "pages": len(reader.pages),
                "page_sizes_points": sizes,
                "encrypted": reader.is_encrypted,
                "empty_text_pages_zero_based": [
                    index for index, length in enumerate(text_lengths) if length == 0
                ],
                "min_text_characters": min(text_lengths, default=0),
                "max_text_characters": max(text_lengths, default=0),
                "page_labels": len(labels),
                "first_page_label": labels[0] if labels else None,
                "last_page_label": labels[-1] if labels else None,
                "outline_items": count_outline(reader.outline),
                "annotations": dict(sorted(annotations.items())),
                "metadata": {
                    "title": reader.metadata.title if reader.metadata else None,
                    "author": reader.metadata.author if reader.metadata else None,
                    "subject": reader.metadata.subject if reader.metadata else None,
                },
            }
        )
        result["ok"] = bool(reader.pages) and not reader.is_encrypted and not result[
            "empty_text_pages_zero_based"
        ]
    except Exception as error:  # Preserve the parser failure in machine-readable output.
        result["error"] = f"{type(error).__name__}: {error}"
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pdfs", nargs="+", type=Path)
    parser.add_argument("--json", action="store_true", help="emit one JSON array")
    args = parser.parse_args()

    results = [audit(path) for path in args.pdfs]
    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    else:
        for result in results:
            print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if all(result["ok"] for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
