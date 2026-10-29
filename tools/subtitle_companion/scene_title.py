"""Resumable, bounded whole-file detector tracks and cue placement proposals.

Anonymous associations stop at cuts and uncertain matches. Missing detections
are never emitted as observed locations. No remote vision provider is used.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import subprocess
import threading

from bitmap_ocr import stop
from scene_objects import Detector
from scene_motion import WIDTH, HEIGHT

MAX_MS = 8 * 3600000
MAX_ARTIFACT = 32 * 1024**2
FORMATS = 'matroska,webm,mov,avi,mpegts,mpeg'
NAME = 'scene-tracks.jsonl'


def _duration(folder):
    result = subprocess.run([os.environ.get('PLEZY_FFPROBE', 'ffprobe'), '-v', 'error',
        '-protocol_whitelist', 'file,pipe', '-format_whitelist', FORMATS,
        '-select_streams', 'v:0', '-show_entries', 'stream=duration:format=duration',
        '-of', 'json', str(folder / 'input.media')], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
    if result.returncode or len(result.stdout) > 32768:
        raise ValueError('scene_title_duration_unavailable')
    data = json.loads(result.stdout)
    streams = data.get('streams')
    if not isinstance(streams, list) or len(streams) != 1:
        raise ValueError('scene_title_requires_one_selected_video_stream')
    value = streams[0].get('duration', data.get('format', {}).get('duration'))
    try: seconds = float(value)
    except (TypeError, ValueError): raise ValueError('scene_title_duration_unavailable') from None
    if not math.isfinite(seconds) or not 0 < seconds <= MAX_MS / 1000:
        raise ValueError('scene_title_eight_hour_limit')
    return math.ceil(seconds * 1000)


def _frames(folder, start_frame, duration_ms):
    """Decode one fixed-grid frame at a time, bounding each pipe read."""
    command = [os.environ.get('PLEZY_FFMPEG', 'ffmpeg'), '-nostdin', '-hide_banner', '-loglevel', 'error',
        '-protocol_whitelist', 'file,pipe', '-format_whitelist', FORMATS,
        '-threads', '2', '-filter_threads', '1', '-ss', str(start_frame),
        '-i', str(folder / 'input.media'), '-map', '0:v:0', '-an', '-sn',
        '-t', str(duration_ms / 1000 - start_frame),
        '-vf', f'scale={WIDTH}:{HEIGHT},fps=1:start_time=0:round=up:eof_action=pass',
        '-pix_fmt', 'rgb24', '-f', 'rawvideo', 'pipe:1']
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    bound = WIDTH * HEIGHT * 3
    try:
        for index in range(start_frame, math.ceil(duration_ms / 1000)):
            timer = threading.Timer(120, stop, (process,)); timer.daemon = True; timer.start()
            try:
                data = bytearray()
                while len(data) < bound:
                    block = process.stdout.read(bound - len(data))
                    if not block: break
                    data.extend(block)
            finally: timer.cancel()
            if len(data) != bound:
                raise ValueError('scene_title_frame_grid_incomplete')
            yield index, data
    finally:
        stop(process); process.wait(); process.stdout.close()


def _overlap(a, b):
    intersection = max(0, min(a[0]+a[2], b[0]+b[2])-max(a[0], b[0])) * max(0, min(a[1]+a[3], b[1]+b[3])-max(a[1], b[1]))
    return intersection / max(1e-9, a[2]*a[3]+b[2]*b[3]-intersection)


def _union(a, b):
    x, y = min(a[0], b[0]), min(a[1], b[1])
    return [x, y, max(a[0]+a[2], b[0]+b[2])-x, max(a[1]+a[3], b[1]+b[3])-y]


def run(folder, job, progress, atomic_json, read_json):
    import cv2
    import numpy as np
    cv2.setNumThreads(2); cv2.ocl.setUseOpenCL(False)
    detector = Detector(job.get('sceneDetectorFingerprint'))
    duration_ms = _duration(folder)
    cues = job['cues']
    if not 0 < len(cues) <= 5000 or max(c['endMs'] for c in cues) > duration_ms:
        raise ValueError('scene_title_cues_exceed_selected_video')
    total_frames = math.ceil(duration_ms / 1000)
    checkpoint, artifact = folder / 'scene-checkpoint.json', folder / NAME
    if checkpoint.is_symlink() or artifact.is_symlink():
        raise ValueError('invalid_scene_title_checkpoint')
    state = {'schema': 1, 'request': job['fingerprint'], 'input': job['audioDigest'],
        'model': detector.fingerprint, 'durationMs': duration_ms, 'nextFrame': 0, 'nextId': 1,
        'scene': 0, 'active': [], 'previousGray': None, 'cuts': 0, 'ambiguousPairs': 0,
        'gapRecoveries': 0, 'observations': 0, 'omittedRegions': 0,
        'cueRegions': {}, 'artifactBytes': 0, 'artifactSha256': hashlib.sha256().hexdigest()}
    digest = hashlib.sha256()
    if checkpoint.exists():
        saved = read_json(checkpoint, 12 * 1024**2)
        if any(saved.get(k) != state[k] for k in ('schema', 'request', 'input', 'model', 'durationMs')):
            raise ValueError('scene_title_checkpoint_identity_changed')
        if (type(saved.get('nextFrame')) is not int or not 0 <= saved['nextFrame'] <= total_frames or
                type(saved.get('artifactBytes')) is not int or not 0 <= saved['artifactBytes'] <= MAX_ARTIFACT or
                not isinstance(saved.get('active'), list) or len(saved['active']) > 48 or
                not isinstance(saved.get('cueRegions'), dict) or len(saved['cueRegions']) > len(cues)):
            raise ValueError('invalid_scene_title_checkpoint')
        with artifact.open('rb') as source:
            remaining = saved['artifactBytes']
            while remaining:
                chunk = source.read(min(1024**2, remaining))
                if not chunk: raise ValueError('scene_title_checkpoint_artifact_truncated')
                digest.update(chunk); remaining -= len(chunk)
        if digest.hexdigest() != saved['artifactSha256']:
            raise ValueError('scene_title_checkpoint_artifact_changed')
        state = saved
    mode = 'r+b' if artifact.exists() else 'w+b'
    with artifact.open(mode) as output:
        output.truncate(state['artifactBytes']); output.seek(state['artifactBytes'])

        def append(value):
            raw = (json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':')) + '\n').encode()
            if state['artifactBytes'] + len(raw) > MAX_ARTIFACT:
                raise ValueError('scene_title_evidence_limit')
            output.write(raw); digest.update(raw); state['artifactBytes'] += len(raw)

        def save():
            output.flush(); os.fsync(output.fileno())
            state['artifactSha256'] = digest.hexdigest()
            atomic_json(checkpoint, state)

        if state['artifactBytes'] == 0:
            append({'schema': 'plezyng.scene-tracks.v1', 'inputSha256': job['audioDigest'],
                'modelFingerprint': detector.fingerprint, 'durationMs': duration_ms, 'gridFps': 1,
                'frameClock': 'ffmpeg-resampled-source-grid', 'qualified': False,
                'row': ['timeMs', 'scene', 'observations'],
                'observation': ['trackId', 'category', 'score', 'left', 'top', 'width', 'height'],
                'labels': {str(k): str(v)[:80] for k, v in detector.model.config.id2label.items()}})
            save()
        active = state['active']
        previous = None if state['previousGray'] is None else np.asarray(state['previousGray'], dtype=np.uint8).reshape(45, 80)
        ordered = sorted(cues, key=lambda c: (c['startMs'], c['endMs'], c['cueId']))
        cue_cursor, active_cues = 0, []

        def histogram(rgb, box):
            x, y, w, h = box
            crop = rgb[int(y*HEIGHT):math.ceil((y+h)*HEIGHT), int(x*WIDTH):math.ceil((x+w)*WIDTH)]
            hsv = cv2.cvtColor(crop, cv2.COLOR_RGB2HSV)
            h = cv2.calcHist([hsv], [0, 1], None, [16, 16], [0, 180, 0, 256])
            h = cv2.normalize(h, h, alpha=1, norm_type=cv2.NORM_L1)
            return [round(float(v), 7) for v in h.reshape(-1)]

        frames = _frames(folder, state['nextFrame'], duration_ms) if state['nextFrame'] < total_frames else iter(())
        try:
            for index, raw in frames:
                time_ms = index * 1000
                rgb = np.frombuffer(raw, dtype=np.uint8).reshape(HEIGHT, WIDTH, 3)
                gray = cv2.resize(cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY), (80, 45), interpolation=cv2.INTER_AREA)
                cut = previous is not None and float(np.mean(np.abs(gray.astype(np.int16)-previous.astype(np.int16)))) > 45
                if cut:
                    active.clear(); state['cuts'] += 1; state['scene'] += 1
                previous = gray
                active[:] = [track for track in active if time_ms-track['lastMs'] <= 3000]
                found = detector.detect(rgb)
                for row in found: row['histogram'] = histogram(rgb, row['box'])
                choices = []
                for t, track in enumerate(active):
                    old_hist = np.asarray(track['histogram'], dtype=np.float32).reshape(16, 16)
                    for d, row in enumerate(found):
                        if track['category'] != row['category']: continue
                        distance = float(cv2.compareHist(old_hist,
                            np.asarray(row['histogram'], dtype=np.float32).reshape(16, 16), cv2.HISTCMP_BHATTACHARYYA))
                        iou = _overlap(track['box'], row['box'])
                        if math.isfinite(distance) and distance <= .25 and iou >= .15:
                            choices.append((.6*iou + .4*(1-distance), t, d))
                used_t, assigned = set(), {}
                for score, t, d in sorted(choices, reverse=True):
                    if t in used_t or d in assigned: continue
                    alternatives = [c[0] for c in choices if (c[1] == t or c[2] == d) and (c[1], c[2]) != (t, d)]
                    if alternatives and score-max(alternatives) < .1:
                        state['ambiguousPairs'] += 1; continue
                    track = active[t]
                    if time_ms-track['lastMs'] > 1000: state['gapRecoveries'] += 1
                    track.update(box=found[d]['box'], histogram=found[d]['histogram'], lastMs=time_ms)
                    assigned[d] = track['id']; used_t.add(t)
                for d, row in enumerate(found):
                    if d in assigned: continue
                    assigned[d] = state['nextId']; state['nextId'] += 1
                    active.append({'id': assigned[d], 'category': row['category'], 'box': row['box'],
                        'histogram': row['histogram'], 'lastMs': time_ms})
                if len(active) > 48: raise ValueError('scene_title_active_track_limit')
                observations = [[assigned[d], row['category'], round(row['score'], 4),
                    *[round(v, 5) for v in row['box']]] for d, row in enumerate(found)]
                append([time_ms, state['scene'], observations])
                state['observations'] += len(observations)

                while cue_cursor < len(ordered) and ordered[cue_cursor]['startMs'] <= time_ms:
                    if ordered[cue_cursor]['endMs'] > time_ms: active_cues.append(ordered[cue_cursor])
                    cue_cursor += 1
                active_cues = [c for c in active_cues if c['endMs'] > time_ms]
                # A pathological set of thousands of simultaneous long cues
                # is refused rather than multiplying work without a bound.
                if len(active_cues) > 64: raise ValueError('scene_title_simultaneous_cue_limit')
                for cue in active_cues:
                    regions = state['cueRegions'].setdefault(cue['cueId'], {})
                    for d, row in enumerate(found):
                        key = str(assigned[d])
                        if key not in regions:
                            if len(regions) >= 12:
                                state['omittedRegions'] += 1; continue
                            regions[key] = {'box': row['box'], 'observations': 1}
                        else:
                            regions[key]['box'] = _union(regions[key]['box'], row['box'])
                            regions[key]['observations'] += 1
                state['nextFrame'] = index + 1
                state['previousGray'] = gray.reshape(-1).tolist()
                if state['nextFrame'] % 60 == 0 or state['nextFrame'] == total_frames: save()
                if state['nextFrame'] % 10 == 0:
                    progress(folder, 'Tracking the chosen video; anonymous proposals', state['nextFrame'] / total_frames)
        finally:
            if hasattr(frames, 'close'): frames.close()
        save()

    avoidance = [{'cueId': cue['cueId'], 'regions': [
        [round(v, 6) for v in row['box']] for row in state['cueRegions'].get(cue['cueId'], {}).values()
        if row['observations'] >= 2]} for cue in cues]
    avoidance = [row for row in avoidance if row['regions']]
    summary = {'durationMs': duration_ms, 'framesObserved': state['nextFrame'], 'expectedFrames': total_frames,
        'frameGridComplete': state['nextFrame'] == total_frames, 'gridFps': 1,
        'cutGates': state['cuts'], 'anonymousTracks': state['nextId']-1,
        'ambiguousPairsRefused': state['ambiguousPairs'], 'shortGapAssociations': state['gapRecoveries'],
        'observations': state['observations'], 'cueRegionsOmitted': state['omittedRegions'],
        'cuesWithProposals': len(avoidance), 'cuesWithoutProposals': len(cues)-len(avoidance),
        'maximumGapMs': 3000, 'modelFingerprint': detector.fingerprint,
        'transformers': detector.version, 'opencv': cv2.__version__, 'qualityQualified': False,
        'association': 'detector-class-iou-color-histogram', 'missingLocationsInterpolated': False}
    return {'cues': [dict(c) for c in cues], 'sourceCues': [dict(c) for c in cues], 'wordTimings': [],
        'language': job.get('language') or 'unknown', 'durationMs': duration_ms,
        'model': 'local-DETR-CPU ' + detector.fingerprint, 'avoidRegions': avoidance,
        'sceneTitleEvidence': [summary], 'artifacts': [{'name': NAME, 'mime': 'application/x-ndjson',
            'bytes': state['artifactBytes'], 'sha256': state['artifactSha256']}],
        'warnings': ['Experimental whole-file anonymous object tracks; detector classes and associations require review. No identities or spoken wording are inferred.',
            'One resampled frame per second can miss short events and cuts. A complete frame grid is not complete scene understanding. Short gaps can be associated but no hidden locations are fabricated.',
            'Placement envelopes include only cue-local observed boxes with at least two samples; changing shots, movement, occlusion and ambiguous appearances can split or confuse tracks.',
            'The media and captions use the chosen file clock. Pause/resume retains verified minute checkpoints; restart can redo up to 59 frames. No quality evaluation was run.']}
