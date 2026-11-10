#!/usr/bin/env python3
"""Reject stale translation-review claims without editing locale catalogs."""
from __future__ import annotations

import hashlib
import json
from datetime import date
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/checks'))
from check_localizations import messages, validate_message  # noqa: E402


def verify(root: Path = ROOT) -> list[str]:
    reviews = root / 'docs/localization/reviews'
    catalogs = root / 'lib/i18n'
    if not reviews.exists():
        return []
    english = messages(json.loads((catalogs / 'en.i18n.json').read_text(encoding='utf-8')))
    errors: list[str] = []
    for path in sorted(reviews.glob('security-completion-*.json')):
        record = json.loads(path.read_text(encoding='utf-8'))
        if not isinstance(record, dict):
            errors.append(f'{path.name}: invalid review records')
            continue
        locale = record.get('locale')
        if not isinstance(locale, str) or not re.fullmatch(r'[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*', locale):
            errors.append(f'{path.name}: invalid locale')
            continue
        reviewed_on = record.get('reviewedOn')
        try:
            if not isinstance(reviewed_on, str) or date.fromisoformat(reviewed_on).isoformat() != reviewed_on:
                raise ValueError('Invalid review date')
        except ValueError:
            errors.append(f'{path.name}: invalid review date')
            continue
        if (record.get('nativeSpeakerReviewed') is not False
                or not isinstance(record.get('reviewMethod'), str) or not record['reviewMethod'].strip()
                or not isinstance(record.get('sourceCommit'), str)
                or not re.fullmatch(r'[0-9a-f]{40}', record['sourceCommit'])):
            errors.append(f'{path.name}: assistant review requires explicit provenance without a native-speaker claim')
            continue
        target_path = catalogs / f'{locale}.i18n.json'
        provenance_path = root / f'docs/localization/provenance/{locale}.json'
        if not target_path.is_file() or not provenance_path.is_file():
            errors.append(f'{path.name}: catalog or provenance missing')
            continue
        translated = messages(json.loads(target_path.read_text(encoding='utf-8')))
        provenance = json.loads(provenance_path.read_text(encoding='utf-8')).get('messages', {})
        entries = record.get('entries')
        if record.get('schemaVersion') != 1 or not isinstance(entries, dict) or not entries:
            errors.append(f'{path.name}: invalid review records')
            continue
        for key, entry in entries.items():
            source = english.get(key)
            if not isinstance(entry, dict) or not isinstance(source, str):
                errors.append(f'{path.name}:{key}: unsupported source or review')
                continue
            if entry.get('source') != source or entry.get('sourceSha256') != hashlib.sha256(source.encode()).hexdigest():
                errors.append(f'{path.name}:{key}: English source changed after review')
            if entry.get('translation') != translated.get(key):
                errors.append(f'{path.name}:{key}: translation changed after review')
            translation = entry.get('translation')
            if not isinstance(translation, str) or not translation.strip():
                errors.append(f'{path.name}:{key}: an empty fallback is not a reviewed translation')
            else:
                errors.extend(validate_message(f'{path.name}:{key}', source, translation))
            if (entry.get('review') != 'assistant-authored-and-semantically-reviewed'
                    or provenance.get(key) != f'assistant-semantic-review-{reviewed_on}'):
                errors.append(f'{path.name}:{key}: provenance does not match review')
    return errors


if __name__ == '__main__':
    problems = verify()
    if problems:
        print('\n'.join(problems))
        sys.exit(1)
    print('Recorded translation reviews match their current source, locale and provenance.')
