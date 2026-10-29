"""Local detector-class/appearance association, not personal identification."""
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re

from scene_motion import WIDTH, HEIGHT, _frames


def _description():
    root = Path(os.environ.get('PLEZY_SCENE_DETECTOR_MODEL', ''))
    if not root.is_absolute() or not root.is_dir():
        raise ValueError('configure_local_scene_detector')
    path = root / 'plezy-model-manifest.json'
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 512 * 1024:
        raise ValueError('prepare_bounded_scene_detector_manifest')
    with path.open('rb') as source:
        data = source.read(512 * 1024 + 1)
    if len(data) > 512 * 1024:
        raise ValueError('scene_detector_manifest_limit')
    manifest = json.loads(data)
    if not isinstance(manifest, dict) or manifest.get('schema') != 1 or manifest.get('purpose') != 'scene-object-detection' or not isinstance(manifest.get('files'), list) or len(manifest['files']) > 100:
        raise ValueError('prepare_scene_object_detection_pack')
    return root, manifest, hashlib.sha256(data).hexdigest()


def capabilities():
    if any(importlib.util.find_spec(module) is None for module in ('torch', 'transformers', 'timm', 'cv2', 'safetensors')):
        return None
    try:
        _, _, digest = _description()
        return {'fingerprint': digest, 'runtime': 'local-DETR-CPU', 'qualified': False,
                'gridFps': 2, 'maximumGapMs': 1500, 'maximumCueMs': 12000, 'maximumTotalMs': 120000}
    except (ValueError, OSError, TypeError):
        return None


class Detector:
    def __init__(self, expected):
        root, manifest, self.fingerprint = _description()
        if expected != self.fingerprint:
            raise ValueError('scene_detector_changed_resubmit_after_review')
        files, total = set(), 0
        for row in manifest['files']:
            name = row.get('path') if isinstance(row, dict) else None
            if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,159}', name) or name in files:
                raise ValueError('unsupported_scene_model_member_path')
            path = root / name
            size = row.get('bytes')
            if type(size) is not int or size < 0 or not path.is_file() or path.is_symlink() or path.stat().st_size != size:
                raise ValueError('scene_model_size_changed')
            total += size
            if total > 1024**3 or name.endswith('.json') and size > 512 * 1024:
                raise ValueError('scene_model_byte_limit')
            digest = hashlib.sha256()
            with path.open('rb') as source:
                remaining = size
                while remaining:
                    chunk = source.read(min(1024**2, remaining))
                    if not chunk:
                        raise ValueError('scene_model_truncated')
                    digest.update(chunk); remaining -= len(chunk)
                if source.read(1):
                    raise ValueError('scene_model_grew')
            if digest.hexdigest() != row.get('sha256'):
                raise ValueError('scene_model_integrity_failed')
            files.add(name)
        if not {'config.json', 'preprocessor_config.json', 'model.safetensors'} <= files:
            raise ValueError('scene_detector_requires_single_safetensors_pack')
        config = json.loads((root / 'config.json').read_text(encoding='utf-8'))
        if (config.get('model_type') != 'detr' or config.get('architectures') != ['DetrForObjectDetection'] or
                config.get('auto_map') or config.get('backbone_config') or
                config.get('backbone', 'resnet50') not in {'resnet50', 'resnet101'} or config.get('use_timm_backbone', True) is not True):
            raise ValueError('unsupported_local_scene_detector_architecture')
        for key, limit in [('num_queries', 300), ('d_model', 512), ('encoder_layers', 12), ('decoder_layers', 12)]:
            if type(config.get(key)) is not int or not 1 <= config[key] <= limit:
                raise ValueError('scene_detector_configuration_limit')
        if not isinstance(config.get('id2label'), dict) or not 1 <= len(config['id2label']) <= 1000:
            raise ValueError('scene_detector_label_limit')
        for key in ('encoder_ffn_dim', 'decoder_ffn_dim'):
            if type(config.get(key, 2048)) is not int or not 1 <= config.get(key, 2048) <= 4096:
                raise ValueError('scene_detector_feedforward_limit')
        import torch
        import transformers
        from transformers import DetrConfig, DetrForObjectDetection, DetrImageProcessor
        torch.set_num_threads(2)
        self.torch, self.version = torch, transformers.__version__
        specification = DetrConfig.from_pretrained(str(root), local_files_only=True)
        # A local full checkpoint contains the backbone. Never fetch timm weights.
        specification.use_pretrained_backbone = False
        specification.backbone_kwargs = None
        self.model = DetrForObjectDetection.from_pretrained(str(root), config=specification,
            local_files_only=True, use_safetensors=True).to('cpu').eval()
        self.processor = DetrImageProcessor.from_pretrained(str(root), local_files_only=True)

    def detect(self, rgb):
        inputs = self.processor(images=rgb, return_tensors='pt', do_resize=False, do_pad=False)
        with self.torch.inference_mode():
            output = self.model(**inputs)
        found = self.processor.post_process_object_detection(output, threshold=.75,
            target_sizes=self.torch.tensor([[HEIGHT, WIDTH]]))[0]
        result = []
        for score, category, bounds in zip(found['scores'], found['labels'], found['boxes']):
            x, y, right, bottom = bounds.tolist()
            score, category = float(score), int(category)
            if not all(math.isfinite(v) for v in (x, y, right, bottom, score)):
                continue
            x, y, right, bottom = max(0, x), max(0, y), min(WIDTH, right), min(HEIGHT, bottom)
            if right-x < 8 or bottom-y < 8:
                continue
            label = str(self.model.config.id2label.get(category, f'class-{category}'))
            if len(label) > 80 or any(ord(c) < 32 for c in label):
                label = f'class-{category}'
            result.append({'category': category, 'label': label, 'score': score,
                'box': [x/WIDTH, y/HEIGHT, (right-x)/WIDTH, (bottom-y)/HEIGHT]})
        return sorted(result, key=lambda row: row['score'], reverse=True)[:12]


def track_objects(folder, cue, detector):
    import cv2
    import numpy as np
    cv2.setNumThreads(2); cv2.ocl.setUseOpenCL(False)
    tracks, previous, frames, cuts, omitted, ambiguities = [], None, 0, 0, 0, 0
    stream = _frames(folder, cue, fps=2, rgb=True)
    def histogram(rgb, box):
        x, y, w, h = box
        crop = rgb[int(y*HEIGHT):math.ceil((y+h)*HEIGHT), int(x*WIDTH):math.ceil((x+w)*WIDTH)]
        hsv = cv2.cvtColor(crop, cv2.COLOR_RGB2HSV)
        hist = cv2.calcHist([hsv], [0, 1], None, [16, 16], [0, 180, 0, 256])
        return cv2.normalize(hist, hist, alpha=1, norm_type=cv2.NORM_L1)
    def overlap(a, b):
        x = max(0, min(a[0]+a[2], b[0]+b[2])-max(a[0], b[0]))
        y = max(0, min(a[1]+a[3], b[1]+b[3])-max(a[1], b[1]))
        return x*y / max(1e-9, a[2]*a[3]+b[2]*b[3]-x*y)
    try:
        for time_ms, raw in stream:
            rgb = np.frombuffer(raw, dtype=np.uint8).reshape(HEIGHT, WIDTH, 3)
            gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
            frames += 1
            for track in tracks:
                if not track['ended'] and time_ms-track['lastMs'] > 1500:
                    track['ended'] = True; track['stopReason'] = 'gap-budget-exceeded'
            if previous is not None and float(np.mean(np.abs(gray.astype(np.int16)-previous.astype(np.int16)))) > 45:
                cuts += 1
                for track in tracks:
                    if not track['ended']:
                        track['ended'] = True; track['stopReason'] = 'cut-or-flash-gate'
            previous = gray
            found = detector.detect(rgb)
            for row in found:
                row['histogram'] = histogram(rgb, row['box'])
            choices = []
            for t, track in enumerate(tracks):
                if track['ended'] or time_ms-track['lastMs'] > 1500:
                    continue
                for d, row in enumerate(found):
                    if track['category'] != row['category']:
                        continue
                    distance = float(cv2.compareHist(track['histogram'], row['histogram'], cv2.HISTCMP_BHATTACHARYYA))
                    iou = overlap(track['box'], row['box'])
                    if distance <= .25 and iou >= .15:
                        choices.append((.6*iou + .4*(1-distance), t, d, distance))
            used_t, used_d = set(), set()
            for score, t, d, distance in sorted(choices, reverse=True):
                if t in used_t or d in used_d:
                    continue
                alternatives = [other[0] for other in choices if (other[1] == t or other[2] == d) and (other[1], other[2]) != (t, d)]
                if alternatives and score-max(alternatives) < .1:
                    ambiguities += 1
                    continue
                track, row = tracks[t], found[d]
                gap = time_ms-track['lastMs']
                track['samples'].append({'timeMs': time_ms, 'region': row['box'], 'detectorScore': row['score'],
                    'appearanceDistance': distance, 'gapRecoveredMs': gap if gap > 500 else 0})
                track.update(box=row['box'], histogram=row['histogram'], lastMs=time_ms)
                used_t.add(t); used_d.add(d)
            for d, row in enumerate(found):
                if d in used_d:
                    continue
                if len(tracks) >= 64:
                    omitted += 1; continue
                tracks.append({'id': f'object-{len(tracks)+1}', **row, 'lastMs': time_ms, 'ended': False,
                    'samples': [{'timeMs': time_ms, 'region': row['box'], 'detectorScore': row['score'], 'gapRecoveredMs': 0}]})
    finally:
        stream.close()
    proposals = []
    for track in tracks:
        if len(track['samples']) < 2:
            continue
        boxes = [row['region'] for row in track['samples']]
        left, top = min(b[0] for b in boxes), min(b[1] for b in boxes)
        right, bottom = max(b[0]+b[2] for b in boxes), max(b[1]+b[3] for b in boxes)
        proposals.append({'id': track['id'], 'label': track['label'], 'samples': track['samples'],
            'association': 'local-detector-class-appearance-unqualified', 'envelope': [left, top, right-left, bottom-top],
            'stopReason': track.get('stopReason', 'cue-bound-or-missing-detection')})
    proposals.sort(key=lambda track: len(track['samples']), reverse=True)
    return {'tracks': proposals, 'framesObserved': frames, 'cutGates': cuts, 'ambiguousPairsRefused': ambiguities,
        'newTracksOmitted': omitted, 'gridFps': 2, 'maximumGapMs': 1500, 'modelFingerprint': detector.fingerprint,
        'runtime': 'local-DETR-CPU', 'transformers': detector.version, 'opencv': cv2.__version__, 'qualityQualified': False,
        'frameClock': 'ffmpeg-resampled-cue-grid', 'startMs': cue['startMs'], 'endMs': cue['endMs']}
