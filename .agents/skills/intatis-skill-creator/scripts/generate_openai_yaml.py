#!/usr/bin/env python3
"""Generate optional Codex-compatible interface metadata for an Agent Skill.

Modified by Intatis from the OpenAI Codex skill-creator sample; see
ThirdPartyNotices/OpenAICodexSkillCreator.md. This adaptation intentionally
uses only the Python standard library. It does not configure MCP servers or
grant any tool capability.
"""

import argparse
import re
import sys
from pathlib import Path


ACRONYMS = {
    "API",
    "CI",
    "CLI",
    "GH",
    "LLM",
    "MCP",
    "PDF",
    "PR",
    "SQL",
    "UI",
    "URL",
}

BRANDS = {
    "datadog": "Datadog",
    "fastapi": "FastAPI",
    "github": "GitHub",
    "openai": "OpenAI",
    "openapi": "OpenAPI",
    "pagerduty": "PagerDuty",
    "sqlite": "SQLite",
}

SMALL_WORDS = {"and", "or", "to", "up", "with"}
ALLOWED_INTERFACE_KEYS = {
    "brand_color",
    "default_prompt",
    "display_name",
    "icon_large",
    "icon_small",
    "short_description",
}


def yaml_quote(value):
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
    )
    return '"{}"'.format(escaped)


def format_display_name(skill_name):
    formatted = []
    for index, word in enumerate(part for part in skill_name.split("-") if part):
        lower = word.lower()
        upper = word.upper()
        if upper in ACRONYMS:
            formatted.append(upper)
        elif lower in BRANDS:
            formatted.append(BRANDS[lower])
        elif index > 0 and lower in SMALL_WORDS:
            formatted.append(lower)
        else:
            formatted.append(word.capitalize())
    return " ".join(formatted)


def generate_short_description(display_name):
    candidates = [
        "Help with {} tasks".format(display_name),
        "Help with {} tasks and workflows".format(display_name),
        "Guidance for {} workflows".format(display_name),
        "{} helper".format(display_name),
    ]
    for candidate in candidates:
        if 25 <= len(candidate) <= 64:
            return candidate
    suffix = " helper"
    return "{}{}".format(
        display_name[: 64 - len(suffix)].rstrip(),
        suffix,
    )


def read_frontmatter_name(skill_dir):
    skill_md = Path(skill_dir) / "SKILL.md"
    try:
        content = skill_md.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        print("[ERROR] Cannot read {}: {}".format(skill_md, error))
        return None

    match = re.match(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|\Z)", content, re.DOTALL)
    if not match:
        print("[ERROR] Invalid SKILL.md frontmatter.")
        return None

    for raw_line in match.group(1).splitlines():
        if raw_line[:1].isspace() or raw_line.lstrip().startswith("#"):
            continue
        key, separator, raw_value = raw_line.partition(":")
        if separator and key.strip() == "name":
            value = raw_value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            if value:
                return value
    print("[ERROR] Frontmatter name is missing or invalid.")
    return None


def parse_interface_overrides(raw_overrides):
    overrides = {}
    order = []
    for item in raw_overrides:
        key, separator, value = item.partition("=")
        key = key.strip()
        value = value.strip()
        if not separator or not key:
            raise ValueError("interface overrides must use key=value")
        if key not in ALLOWED_INTERFACE_KEYS:
            raise ValueError(
                "unknown interface field {}; allowed: {}".format(
                    key,
                    ", ".join(sorted(ALLOWED_INTERFACE_KEYS)),
                )
            )
        overrides[key] = value
        if key not in order:
            order.append(key)
    return overrides, order


def write_openai_yaml(skill_dir, skill_name, raw_overrides):
    try:
        overrides, order = parse_interface_overrides(raw_overrides)
    except ValueError as error:
        print("[ERROR] {}".format(error))
        return None

    display_name = overrides.get("display_name") or format_display_name(skill_name)
    short_description = (
        overrides.get("short_description")
        or generate_short_description(display_name)
    )
    if not 25 <= len(short_description) <= 64:
        print(
            "[ERROR] short_description must contain 25 to 64 characters "
            "(got {}).".format(len(short_description))
        )
        return None

    lines = [
        "interface:",
        "  display_name: {}".format(yaml_quote(display_name)),
        "  short_description: {}".format(yaml_quote(short_description)),
    ]
    for key in order:
        if key in {"display_name", "short_description"}:
            continue
        lines.append("  {}: {}".format(key, yaml_quote(overrides[key])))

    agents_dir = Path(skill_dir) / "agents"
    agents_dir.mkdir(parents=True, exist_ok=True)
    output = agents_dir / "openai.yaml"
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("[OK] Created {}".format(output))
    return output


def main():
    parser = argparse.ArgumentParser(
        description="Create optional agents/openai.yaml interface metadata."
    )
    parser.add_argument("skill_dir", help="Skill directory")
    parser.add_argument("--name", help="Override the frontmatter name")
    parser.add_argument(
        "--interface",
        action="append",
        default=[],
        help="Interface override in key=value form; repeat as needed",
    )
    arguments = parser.parse_args()

    skill_dir = Path(arguments.skill_dir).resolve()
    if not skill_dir.is_dir():
        print("[ERROR] Skill directory is missing: {}".format(skill_dir))
        return 1
    skill_name = arguments.name or read_frontmatter_name(skill_dir)
    if not skill_name:
        return 1
    return 0 if write_openai_yaml(
        skill_dir,
        skill_name,
        arguments.interface,
    ) else 1


if __name__ == "__main__":
    sys.exit(main())
