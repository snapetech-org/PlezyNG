#!/usr/bin/env python3
"""Generate pinned-model translation candidates, with reversible per-message QA.

This command writes an artifact. It never edits a catalog or claims human review.
Interpolation mismatches fail the candidate instead of silently changing code.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re
import unicodedata

ROOT = Path(__file__).resolve().parents[2]
MODEL = 'jncraton/m2m100_418M-ct2-int8'
REVISION = '7c1b2620a4e58dacecbd8bf89cfd6da7eb9eb7b0'
PLACEHOLDER = re.compile(r'\$\{[^}]+\}|\$[A-Za-z_]\w*(?:\.\w+)*')
MARKER = re.compile(r'ZXQ\s*([0-9]+)\s*QXZ', re.IGNORECASE)


def flatten(node, prefix=''):
    result = {}
    for key, value in node.items():
        if key.startswith('@'):
            continue
        name = prefix + re.sub(r'\([^)]*\)$', '', key)
        if isinstance(value, dict) and not ('other' in value and set(value) <= {'zero', 'one', 'two', 'few', 'many', 'other'}):
            result.update(flatten(value, name + '.'))
        else:
            result[name] = value
    return result


def protect(text):
    values = []
    def replace(match):
        values.append(match.group())
        return f'ZXQ{len(values) - 1}QXZ'
    return PLACEHOLDER.sub(replace, text), values


def restore(text, values):
    text = unicodedata.normalize('NFC', text)
    seen = []
    def replace(match):
        index = int(match.group(1))
        if index >= len(values):
            raise ValueError('Unknown interpolation marker')
        seen.append(index)
        return values[index]
    result = MARKER.sub(replace, text)
    if Counter(seen) != Counter(range(len(values))) or 'ZXQ' in result.upper() or 'QXZ' in result.upper():
        raise ValueError('Model changed an interpolation marker')
    return result.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--locale', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    catalogs = ROOT / 'lib/i18n'
    catalog = json.loads((catalogs / 'locale_catalog.json').read_text())
    if args.locale not in catalog['locales'] or args.locale == 'en' or args.locale in catalog['regionalParents']:
        parser.error('Choose a non-English base locale')
    english_bytes = (catalogs / 'en.i18n.json').read_bytes()
    source = flatten(json.loads(english_bytes))
    target = flatten(json.loads((catalogs / f'{args.locale}.i18n.json').read_text()))
    keys = json.loads((catalogs / 'english_fallbacks.json').read_text())['keys']
    memory = defaultdict(set)
    for key, value in target.items():
        if isinstance(value, str) and value.strip() and isinstance(source.get(key), str):
            memory[source[key]].add(value)

    from huggingface_hub import snapshot_download
    import ctranslate2
    import sentencepiece
    folder = Path(snapshot_download(MODEL, revision=REVISION))
    models = list(folder.glob('*.model')) + list(folder.glob('*.spm'))
    if len(models) != 1:
        raise RuntimeError('Pinned model must contain exactly one SentencePiece model')
    tokenizer = sentencepiece.SentencePieceProcessor(model_file=str(models[0]))
    translator = ctranslate2.Translator(str(folder), device='cpu', compute_type='int8', inter_threads=1, intra_threads=4)
    language = {'nb': 'no', 'zh-Hant': 'zh'}.get(args.locale, args.locale)

    def translate(text, origin, destination):
        tokens = [f'__{origin}__', *tokenizer.encode(text, out_type=str), '</s>']
        results = translator.translate_batch(
            [tokens], target_prefix=[[f'__{destination}__']], beam_size=4,
            repetition_penalty=1.15, no_repeat_ngram_size=3, max_decoding_length=512,
        )
        output = results[0].hypotheses[0]
        if output and output[0] == f'__{destination}__':
            output = output[1:]
        return tokenizer.decode(output).strip()

    converter = None
    if args.locale == 'zh-Hant':
        from opencc import OpenCC
        converter = OpenCC('s2twp')
    entries, issues = {}, []
    cache = {}

    def candidate(key, text):
        if text in cache:
            return dict(cache[text])
        if len(memory[text]) == 1:
            output = next(iter(memory[text]))
            origin = 'existing-identical-source-translation'
        else:
            masked, values = protect(text)
            try:
                output = restore(translate(masked, 'en', language), values)
                origin = 'm2m100-candidate'
            except ValueError:
                # Preserve each placeholder verbatim; this fallback is marked
                # for contextual review because word order may need correction.
                parts = PLACEHOLDER.split(text)
                variables = PLACEHOLDER.findall(text)
                output = ''.join(
                    (translate(part.strip(), 'en', language) if part.strip() else '')
                    + ((' ' if part.strip() else '') + variables[n] + ' ' if n < len(variables) else '')
                    for n, part in enumerate(parts)
                ).strip()
                origin = 'm2m100-segmented-candidate'
                issues.append({'key': key, 'reason': 'segmented interpolation needs word-order review'})
        if converter:
            output = converter.convert(output)
        if not output or Counter(PLACEHOLDER.findall(output)) != Counter(PLACEHOLDER.findall(text)):
            raise ValueError(f'Invalid translation candidate: {key}')
        masked, values = protect(output)
        try:
            back = restore(translate(masked, language, 'en'), values)
        except ValueError:
            back = translate(masked, language, 'en')
        if output.casefold() == text.casefold():
            issues.append({'key': key, 'reason': 'unchanged source requires terminology review'})
        record = {'source': text, 'translation': output, 'backTranslation': back, 'origin': origin}
        cache[text] = record
        return dict(record)

    for key in keys:
        existing = target.get(key)
        if isinstance(existing, str) and existing.strip():
            continue
        value = source[key]
        if isinstance(value, str):
            entries[key] = candidate(key, value)
        else:
            entries[key] = {'forms': {form: candidate(f'{key}.{form}', text) for form, text in value.items()}}
        if len(entries) % 50 == 0:
            print(f'{args.locale}: {len(entries)} candidates', flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({
        'schemaVersion': 1, 'locale': args.locale, 'model': MODEL, 'revision': REVISION,
        'sourceSha256': hashlib.sha256(english_bytes).hexdigest(),
        'nativeSpeakerReviewed': False, 'entries': entries, 'reviewIssues': issues,
    }, ensure_ascii=False, indent=2) + '\n')
    print(f'{args.locale}: wrote {len(entries)} candidates and {len(issues)} review flags')


if __name__ == '__main__':
    main()
