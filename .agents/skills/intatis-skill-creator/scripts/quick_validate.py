#!/usr/bin/env python3
"""Validate an Intatis Agent Skill without third-party Python packages.

Modified by Intatis from the OpenAI Codex skill-creator sample; see
ThirdPartyNotices/OpenAICodexSkillCreator.md.
"""

import re
import sys
from pathlib import Path


MAX_NAME_CHARACTERS = 64
MAX_DESCRIPTION_CHARACTERS = 1024
MAX_TEXT_FILE_BYTES = 48 * 1024
MAX_OPENAI_YAML_BYTES = 16 * 1024
ALLOWED_FRONTMATTER_KEYS = {
    "allowed-tools",
    "description",
    "license",
    "metadata",
    "name",
}
NAME_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def secret_markers():
    return (
        "-" * 5 + "BEGIN",
        "PRIVATE" + " KEY",
        "AK" + "IA",
        "AS" + "IA",
        "s" + "k-",
        "ssh" + "-rsa ",
        "xox" + "b-",
        "xox" + "p-",
        "gh" + "p_",
        "github" + "_pat_",
        "AI" + "za",
    )


def strip_quotes(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def parse_frontmatter(content):
    match = re.match(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|\Z)", content, re.DOTALL)
    if not match:
        raise ValueError("missing or malformed leading YAML frontmatter")

    lines = match.group(1).splitlines()
    values = {}
    keys = set()
    index = 0
    while index < len(lines):
        line = lines[index]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            index += 1
            continue
        if line[:1].isspace():
            index += 1
            continue
        key, separator, raw_value = line.partition(":")
        key = key.strip()
        if not separator or not key:
            raise ValueError("invalid top-level frontmatter line")
        if key in keys:
            raise ValueError("duplicate frontmatter field: {}".format(key))
        keys.add(key)
        if key not in ALLOWED_FRONTMATTER_KEYS:
            raise ValueError("unsupported frontmatter field: {}".format(key))

        raw_value = raw_value.strip()
        if raw_value in {">", ">-", ">+", "|", "|-", "|+"}:
            folded = raw_value.startswith(">")
            block = []
            index += 1
            while index < len(lines):
                candidate = lines[index]
                if candidate and not candidate[:1].isspace():
                    break
                block.append(candidate.strip())
                index += 1
            values[key] = (
                " ".join(part for part in block if part)
                if folded
                else "\n".join(block).strip()
            )
            continue

        values[key] = strip_quotes(raw_value)
        index += 1
    return values


def validate_text_resources(skill_path):
    markers = secret_markers()
    for path in sorted(skill_path.rglob("*")):
        if path.is_symlink():
            raise ValueError("symlinks are not allowed: {}".format(path))
        if not path.is_file():
            continue
        size = path.stat().st_size
        relative_path = path.relative_to(skill_path).as_posix()
        maximum_bytes = (
            MAX_OPENAI_YAML_BYTES
            if relative_path == "agents/openai.yaml"
            else MAX_TEXT_FILE_BYTES
        )
        if size > maximum_bytes:
            raise ValueError(
                "text resource exceeds {} KiB: {}".format(
                    maximum_bytes // 1024,
                    path,
                )
            )
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeError:
            raise ValueError(
                "resource is not valid UTF-8: {}".format(path)
            )
        if any(marker in content for marker in markers):
            raise ValueError(
                "resource contains credential-like material: {}".format(path)
            )


def validate_skill(raw_path):
    skill_path = Path(raw_path).resolve()
    if not skill_path.is_dir():
        return False, "Skill directory is missing: {}".format(skill_path)
    skill_md = skill_path / "SKILL.md"
    if not skill_md.is_file() or skill_md.is_symlink():
        return False, "SKILL.md is missing or unsafe"

    try:
        content = skill_md.read_text(encoding="utf-8")
        frontmatter = parse_frontmatter(content)
        validate_text_resources(skill_path)
    except (OSError, UnicodeError, ValueError) as error:
        return False, str(error)

    name = frontmatter.get("name", "").strip()
    description = frontmatter.get("description", "").strip()
    if not NAME_PATTERN.fullmatch(name):
        return False, "name must use lowercase hyphen-case"
    if len(name) > MAX_NAME_CHARACTERS:
        return False, "name exceeds {} characters".format(MAX_NAME_CHARACTERS)
    if skill_path.name != name:
        return False, "directory name must match frontmatter name"
    if not description:
        return False, "description must be non-empty"
    if len(description) > MAX_DESCRIPTION_CHARACTERS:
        return False, "description exceeds {} characters".format(
            MAX_DESCRIPTION_CHARACTERS
        )
    if "<" in description or ">" in description:
        return False, "description cannot contain angle brackets"
    if "TODO" in content:
        return False, "SKILL.md still contains TODO placeholders"
    return True, "Skill is valid"


def main():
    if len(sys.argv) != 2:
        print("Usage: quick_validate.py <skill-directory>")
        return 2
    valid, message = validate_skill(sys.argv[1])
    print(message)
    return 0 if valid else 1


if __name__ == "__main__":
    sys.exit(main())
