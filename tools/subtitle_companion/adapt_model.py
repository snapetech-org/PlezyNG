#!/usr/bin/env python3
"""Explicit offline Whisper adaptation with disjoint domain/general holdouts.

Never invoked by the HTTP server. Produces an unactivated candidate, a quality
report and optional CTranslate2 export. No model/corpus telemetry or auto upload.
"""
from __future__ import annotations
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import unicodedata
import wave


def digest_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024**2), b''): digest.update(block)
    return digest.hexdigest()


def manifest(path, root):
    if path.stat().st_size > 8 * 1024**2: raise ValueError('manifest_too_large')
    rows = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(rows, list) or not 10 <= len(rows) <= 2000: raise ValueError('need_ten_to_two_thousand_examples_per_split')
    output, identities, clips = [], set(), set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != {'audio', 'text', 'sha256', 'sourceDigest'}: raise ValueError('invalid_example_schema')
        text = row['text']
        if not isinstance(text, str) or not 1 <= len(text) <= 512 or '\0' in text: raise ValueError('invalid_reference_text')
        if any(not isinstance(row[k], str) or not re.fullmatch(r'[0-9a-f]{64}', row[k]) for k in ('sha256', 'sourceDigest')):
            raise ValueError('invalid_corpus_identity')
        audio = (root / row['audio']).resolve()
        if not audio.is_relative_to(root) or not audio.is_file() or not 44 < audio.stat().st_size <= 1000000:
            raise ValueError('clip_must_be_bounded_local_wav')
        if row['sha256'] in clips: raise ValueError('duplicate_clip_in_split')
        clips.add(row['sha256']); identities.add(row['sourceDigest'])
        output.append({**row, 'path': audio})
    return output, identities, clips


def samples(row):
    import numpy as np
    data = row['path'].read_bytes()
    if len(data) > 1000000 or hashlib.sha256(data).hexdigest() != row['sha256']: raise ValueError('clip_changed')
    with wave.open(io.BytesIO(data), 'rb') as stream:
        if stream.getnchannels() != 1 or stream.getsampwidth() != 2 or stream.getframerate() != 16000 or not 1600 <= stream.getnframes() <= 480000:
            raise ValueError('clips_require_point_one_to_thirty_seconds_mono_sixteen_khz_pcm16')
        return np.frombuffer(stream.readframes(stream.getnframes()), dtype='<i2').astype(np.float32) / 32768


def tokens(text):
    # Report this normalization exactly: it is not a multilingual accuracy oracle.
    return ''.join(' ' if unicodedata.category(c).startswith('P') else c for c in unicodedata.normalize('NFKC', text).casefold()).split()


def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        row = [i]
        for j, y in enumerate(b, 1): row.append(min(row[-1] + 1, previous[j] + 1, previous[j-1] + (x != y)))
        previous = row
    return previous[-1]


def evaluate(model, processor, rows, device):
    import torch
    model.eval()
    errors = total = char_errors = chars = 0
    with torch.no_grad():
        for row in rows:
            features = processor(samples(row), sampling_rate=16000, return_tensors='pt').input_features.to(device)
            output = model.generate(features, max_new_tokens=224, num_beams=1, do_sample=False)
            hypothesis = processor.batch_decode(output, skip_special_tokens=True)[0]
            ref, hyp = tokens(row['text']), tokens(hypothesis)
            errors += distance(ref, hyp); total += len(ref)
            ref_chars, hyp_chars = ''.join(ref), ''.join(hyp)
            char_errors += distance(ref_chars, hyp_chars); chars += len(ref_chars)
    if not total or not chars: raise ValueError('empty_holdout_reference')
    return {'wer': errors / total, 'cer': char_errors / chars, 'referenceWords': total, 'referenceCharacters': chars, 'examples': len(rows)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True, help='Local HF Whisper tiny/base checkpoint with safetensors')
    parser.add_argument('--corpus', type=Path, required=True)
    parser.add_argument('--train', type=Path, required=True)
    parser.add_argument('--domain-eval', type=Path, required=True)
    parser.add_argument('--general-eval', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--language', required=True)
    parser.add_argument('--license', required=True, help='Declared model and corpus usage/license record')
    parser.add_argument('--device', choices=['cpu', 'cuda'], default='cpu')
    parser.add_argument('--steps', type=int, default=200)
    parser.add_argument('--seed', type=int, default=17)
    parser.add_argument('--export-ctranslate2', action='store_true')
    args = parser.parse_args()
    if not 1 <= args.steps <= 2000 or not re.fullmatch(r'[a-z]{2,3}', args.language) or not 1 <= len(args.license) <= 2000:
        parser.error('Invalid steps, language or license record')
    base, root, destination = args.base.resolve(), args.corpus.resolve(), args.output.resolve()
    if not base.is_dir() or not root.is_dir() or destination.exists(): parser.error('Use existing local model/corpus directories and a new output path')
    if destination.is_relative_to(base) or destination.is_relative_to(root): parser.error('Candidate output must be outside the model and corpus')
    config_path = base / 'config.json'
    if config_path.stat().st_size > 1024**2: raise ValueError('model_config_limit')
    config = json.loads(config_path.read_text())
    if config.get('model_type') != 'whisper' or config.get('d_model', 999999) > 512: raise ValueError('adaptation_supports_whisper_tiny_or_base')
    if not list(base.glob('*.safetensors')): raise ValueError('safetensors_checkpoint_required')
    splits = [manifest(path, root) for path in (args.train, args.domain_eval, args.general_eval)]
    for i in range(3):
        for j in range(i):
            if splits[i][1] & splits[j][1] or splits[i][2] & splits[j][2]: raise ValueError('holdouts_must_not_share_source_groups_or_clips')
    for rows, _, _ in splits:
        for row in rows: samples(row)  # Validate every immutable input before loading a model.
    os.environ['HF_HUB_OFFLINE'] = '1'; os.environ['TRANSFORMERS_OFFLINE'] = '1'; os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
    os.environ['WANDB_DISABLED'] = 'true'
    import torch
    from transformers import WhisperProcessor, WhisperForConditionalGeneration, Seq2SeqTrainer, Seq2SeqTrainingArguments, set_seed
    torch.set_num_threads(min(4, os.cpu_count() or 1)); set_seed(args.seed)
    if args.device == 'cuda' and not torch.cuda.is_available(): raise ValueError('requested_cuda_unavailable')
    processor = WhisperProcessor.from_pretrained(str(base), local_files_only=True, language=args.language, task='transcribe')
    model = WhisperForConditionalGeneration.from_pretrained(str(base), local_files_only=True, use_safetensors=True).to(args.device)
    model.generation_config.language = args.language; model.generation_config.task = 'transcribe'
    model.generation_config.forced_decoder_ids = None; model.config.forced_decoder_ids = None
    before = {name: evaluate(model, processor, split[0], args.device) for name, split in zip(('domain', 'general'), splits[1:])}
    class Corpus(torch.utils.data.Dataset):
        def __len__(self): return len(splits[0][0])
        def __getitem__(self, index):
            row = splits[0][0][index]
            labels = processor.tokenizer(row['text']).input_ids
            if len(labels) > model.config.max_target_positions: raise ValueError('reference_exceeds_model_token_limit')
            return {'input_features': processor.feature_extractor(samples(row), sampling_rate=16000).input_features[0],
                    'labels': labels}
    def collate(rows):
        batch = processor.feature_extractor.pad([{'input_features': r['input_features']} for r in rows], return_tensors='pt')
        labels = processor.tokenizer.pad([{'input_ids': r['labels']} for r in rows], return_tensors='pt')
        values = labels['input_ids'].masked_fill(labels.attention_mask.ne(1), -100)
        if (values[:, 0] == model.config.decoder_start_token_id).all().item(): values = values[:, 1:]
        batch['labels'] = values
        return batch
    destination.mkdir(parents=True)
    model.config.use_cache = False
    training = Seq2SeqTrainingArguments(output_dir=str(destination / 'training'), use_cpu=args.device == 'cpu',
        per_device_train_batch_size=1, gradient_accumulation_steps=8, learning_rate=1e-5, max_steps=args.steps,
        warmup_steps=min(20, args.steps // 10), save_strategy='no', logging_strategy='no', report_to=[],
        dataloader_num_workers=0, remove_unused_columns=False, fp16=False, bf16=False, seed=args.seed, push_to_hub=False)
    trainer = Seq2SeqTrainer(model=model, args=training, train_dataset=Corpus(), data_collator=collate,
                            processing_class=processor.feature_extractor)
    trainer.train()
    model.config.use_cache = True
    after = {name: evaluate(model, processor, split[0], args.device) for name, split in zip(('domain', 'general'), splits[1:])}
    accepted = after['domain']['wer'] < before['domain']['wer'] and after['general']['wer'] <= before['general']['wer'] and after['general']['cer'] <= before['general']['cer']
    checkpoint = destination / 'candidate-hf'
    model.save_pretrained(checkpoint, safe_serialization=True); processor.save_pretrained(checkpoint)
    report = {'schema': 1, 'activated': False, 'recommendation': 'candidate_for_manual_review' if accepted else 'do_not_promote',
        'baseline': before, 'candidate': after, 'seed': args.seed, 'steps': args.steps, 'language': args.language,
        'deviceRequest': args.device, 'perOperationPlacement': 'unverified', 'licenseDeclaration': args.license,
        'baseConfigSha256': digest_file(config_path), 'corpusManifestSha256': [digest_file(path) for path in (args.train, args.domain_eval, args.general_eval)],
        'normalization': 'Unicode NFKC/casefold, punctuation to spaces; CER excludes whitespace',
        'limits': 'Disjoint declared source groups reduce leakage but do not establish speaker/title independence or general population accuracy.'}
    if accepted and args.export_ctranslate2:
        from ctranslate2.converters import TransformersConverter
        TransformersConverter(str(checkpoint), trust_remote_code=False, copy_files=['tokenizer.json', 'preprocessor_config.json']).convert(
            str(destination / 'candidate-ctranslate2'), quantization='int8', force=False)
        report['export'] = 'candidate-ctranslate2'
    report['artifacts'] = [{'path': str(path.relative_to(destination)), 'bytes': path.stat().st_size, 'sha256': digest_file(path)}
        for path in sorted(destination.rglob('*')) if path.is_file()]
    (destination / 'adaptation-report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print('Candidate and report saved. No host model was activated. Review the two holdouts before changing host configuration.')


if __name__ == '__main__':
    main()
