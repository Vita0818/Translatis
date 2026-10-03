#!/usr/bin/env python3
"""Create an Intatis Agent Skill skeleton inside an explicitly selected root.

Modified by Intatis from the OpenAI Codex skill-creator sample; see
ThirdPartyNotices/OpenAICodexSkillCreator.md. This adaptation uses the project
`.agents/skills` root by default.
"""

import argparse
import re
import sys
from pathlib import Path

from generate_openai_yaml import write_openai_yaml


MAX_SKILL_NAME_LENGTH = 64
ALLOWED_RESOURCES = {"references", "scripts"}

SKILL_TEMPLATE = """---
name: {skill_name}
description: TODO describe what this Skill does and the concrete requests that should activate it.
---

# {skill_title}

## Workflow

TODO replace this placeholder with direct operational instructions.

## Validation

TODO state the checks that prove this Skill completed its work.
"""

EXAMPLE_SCRIPT = '''#!/usr/bin/env python3
"""Example deterministic helper for {skill_name}."""


def main():
    print("Replace this example with the real helper.")


if __name__ == "__main__":
    main()
'''

EXAMPLE_REFERENCE = """# Reference for {skill_title}

Replace this placeholder with detailed information needed only for some activations.
"""


def normalize_skill_name(raw_name):
    normalized = re.sub(r"[^a-z0-9]+", "-", raw_name.strip().lower())
    normalized = re.sub(r"-{2,}", "-", normalized).strip("-")
    return normalized


def title_case_skill_name(skill_name):
    return " ".join(part.capitalize() for part in skill_name.split("-"))


def parse_resources(raw_resources):
    if not raw_resources:
        return []
    values = []
    for value in raw_resources.split(","):
        value = value.strip()
        if not value or value in values:
            continue
        if value not in ALLOWED_RESOURCES:
            raise ValueError(
                "unknown resource {}; allowed: {}".format(
                    value,
                    ", ".join(sorted(ALLOWED_RESOURCES)),
                )
            )
        values.append(value)
    return values


def create_resources(skill_dir, skill_name, skill_title, resources, examples):
    for resource in resources:
        resource_dir = skill_dir / resource
        resource_dir.mkdir()
        if not examples:
            continue
        if resource == "scripts":
            path = resource_dir / "example.py"
            path.write_text(
                EXAMPLE_SCRIPT.format(skill_name=skill_name),
                encoding="utf-8",
            )
        elif resource == "references":
            path = resource_dir / "reference.md"
            path.write_text(
                EXAMPLE_REFERENCE.format(skill_title=skill_title),
                encoding="utf-8",
            )


def initialize(
    skill_name,
    output_root,
    resources,
    examples,
    portable_metadata,
    interface_overrides,
):
    output_root = Path(output_root).resolve()
    if output_root.exists() and not output_root.is_dir():
        print("[ERROR] Output root is not a directory: {}".format(output_root))
        return None
    output_root.mkdir(parents=True, exist_ok=True)

    skill_dir = output_root / skill_name
    if skill_dir.exists():
        print("[ERROR] Skill directory already exists: {}".format(skill_dir))
        return None

    skill_dir.mkdir()
    skill_title = title_case_skill_name(skill_name)
    (skill_dir / "SKILL.md").write_text(
        SKILL_TEMPLATE.format(
            skill_name=skill_name,
            skill_title=skill_title,
        ),
        encoding="utf-8",
    )
    create_resources(
        skill_dir,
        skill_name,
        skill_title,
        resources,
        examples,
    )

    if portable_metadata or interface_overrides:
        if not write_openai_yaml(
            skill_dir,
            skill_name,
            interface_overrides,
        ):
            print(
                "[ERROR] Skill skeleton exists, but portable metadata "
                "generation failed: {}".format(skill_dir)
            )
            return None

    print("[OK] Created Skill skeleton: {}".format(skill_dir))
    print("Next: replace every TODO, then run quick_validate.py.")
    return skill_dir


def main():
    parser = argparse.ArgumentParser(
        description="Create an Intatis Agent Skill skeleton."
    )
    parser.add_argument("skill_name", help="Skill name; normalized to hyphen-case")
    parser.add_argument(
        "--path",
        default=".agents/skills",
        help="Destination root; defaults to the current workspace's .agents/skills",
    )
    parser.add_argument(
        "--resources",
        default="",
        help="Comma-separated resources: scripts,references",
    )
    parser.add_argument(
        "--examples",
        action="store_true",
        help="Create text placeholders in selected resource directories",
    )
    parser.add_argument(
        "--portable-metadata",
        action="store_true",
        help="Create optional Codex-compatible interface metadata",
    )
    parser.add_argument(
        "--interface",
        action="append",
        default=[],
        help="Portable interface override in key=value form",
    )
    arguments = parser.parse_args()

    skill_name = normalize_skill_name(arguments.skill_name)
    if not skill_name:
        print("[ERROR] Skill name must contain a letter or digit.")
        return 1
    if len(skill_name) > MAX_SKILL_NAME_LENGTH:
        print(
            "[ERROR] Skill name exceeds {} characters.".format(
                MAX_SKILL_NAME_LENGTH
            )
        )
        return 1
    if skill_name != arguments.skill_name:
        print(
            "[INFO] Normalized {} to {}.".format(
                arguments.skill_name,
                skill_name,
            )
        )

    try:
        resources = parse_resources(arguments.resources)
    except ValueError as error:
        print("[ERROR] {}".format(error))
        return 1
    if arguments.examples and not resources:
        print("[ERROR] --examples requires --resources.")
        return 1

    created = initialize(
        skill_name,
        arguments.path,
        resources,
        arguments.examples,
        arguments.portable_metadata,
        arguments.interface,
    )
    return 0 if created else 1


if __name__ == "__main__":
    sys.exit(main())
