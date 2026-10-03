#!/usr/bin/env python3

"""Emit deterministic installed-wheel metadata for the document runtime build."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import re


def distributions() -> list[tuple[str, str, str]]:
    resolved: dict[str, tuple[str, str, str]] = {}
    for distribution in importlib.metadata.distributions():
        name = distribution.metadata.get("Name") or distribution.name
        version = distribution.version
        expression = distribution.metadata.get("License-Expression")
        legacy = distribution.metadata.get("License")
        if expression and expression.strip():
            license_declared = expression.strip()
        elif legacy and "\n" not in legacy and len(legacy.strip()) <= 100:
            license_declared = legacy.strip()
        else:
            license_declared = "NOASSERTION"
        key = re.sub(r"[-_.]+", "-", name).lower()
        resolved[key] = (name, version, license_declared)
    return [resolved[key] for key in sorted(resolved)]


def spdx_id(name: str, version: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9.-]", "-", f"{name}-{version}")
    return f"SPDXRef-Python-{safe}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--format",
        choices=("spdx-packages", "license-inventory"),
        required=True,
    )
    arguments = parser.parse_args()
    values = distributions()
    if arguments.format == "license-inventory":
        for name, version, license_declared in values:
            print(f"{name}\t{version}\t{license_declared}")
        return
    packages = [
        {
            "name": name,
            "SPDXID": spdx_id(name, version),
            "versionInfo": version,
            "downloadLocation": f"https://pypi.org/project/{name}/{version}/",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": license_declared,
            "copyrightText": "NOASSERTION",
        }
        for name, version, license_declared in values
    ]
    print(json.dumps(packages, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
