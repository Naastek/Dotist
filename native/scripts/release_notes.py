#!/usr/bin/env python3
"""Parse and validate localized release notes from docs/release-notes.md."""
from pathlib import Path
import re

SUPPORTED_LANGUAGES = ('en', 'zh-CN', 'zh-TW', 'fr', 'de')
DEFAULT_LANGUAGE = 'en'
_HEADING_RE = re.compile(r'^##\s+.+?<!--\s*lang:([A-Za-z0-9-]+)\s*-->\s*$')


def _plain_text(markdown: str) -> str:
    return markdown.strip().replace('**', '')


def parse_release_notes(text: str) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    current_lang: str | None = None
    for raw_line in text.splitlines():
        match = _HEADING_RE.match(raw_line.strip())
        if match:
            lang = match.group(1)
            if lang not in SUPPORTED_LANGUAGES:
                raise ValueError(f'Unsupported release note language: {lang}')
            if lang in sections:
                raise ValueError(f'Duplicate release note language section: {lang}')
            sections[lang] = []
            current_lang = lang
        elif current_lang is not None:
            sections[current_lang].append(raw_line)

    missing = [lang for lang in SUPPORTED_LANGUAGES if lang not in sections]
    if missing:
        raise ValueError(f'Missing release note sections for languages: {", ".join(missing)}')

    result: dict[str, str] = {}
    for lang in SUPPORTED_LANGUAGES:
        body = _plain_text('\n'.join(sections[lang]))
        if not body:
            raise ValueError(f'Empty release note section for language: {lang}')
        result[lang] = body
    return result


def load_release_notes(path: Path) -> dict[str, str]:
    return parse_release_notes(path.read_text(encoding='utf-8'))
