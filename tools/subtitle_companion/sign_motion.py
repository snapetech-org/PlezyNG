"""Opt-in local sign-region motion evidence, never semantic sign identity."""
from __future__ import annotations

import math

from scene_motion import track_regions, FPS


def track(folder, job, result, progress):
    # OCR remains the wording/timing proposal. Motion starts from the explicitly
    # selected region, which may contain background texture as well as a sign.
    # Do not reacquire after a failed correspondence or pretend a hidden sign
    # remained observed. Decode and retained evidence have a two-minute bound.
    if result['durationMs'] > 120000 or len(result['cues']) > 120:
        raise ValueError('sign_motion_requires_at_most_two_minutes_120_cues')
    observations = []
    for index, cue in enumerate(result['cues']):
        start, end = cue['startMs'], cue['endMs']
        seed = list(cue['region'])
        samples, windows = [], []
        complete = True
        for at in range(start, end, 12000):
            stop = min(at + 12000, end)
            motion = track_regions(folder, {'startMs': at, 'endMs': stop}, [seed])
            windows.append({'startMs': at, 'endMs': stop, 'status': motion['status'],
                            'framesObserved': motion['framesObserved']})
            paths = motion['tracks']
            if len(paths) != 1:
                complete = False
                break
            path = paths[0]
            samples.extend(path['samples'])
            # Last point is a sample, not an inferred hidden position. The
            # fixed-grid coverage tolerance is one frame plus rounding.
            if (path['stopReason'] != 'completed-frame-grid' or
                    path['samples'][-1]['timeMs'] < stop - math.ceil(1000 / FPS) - 1):
                complete = False
                break
            seed = path['samples'][-1]['region']
        envelope = None
        if complete and len(samples) >= 2:
            left = min(row['region'][0] for row in samples)
            top = min(row['region'][1] for row in samples)
            right = max(row['region'][0] + row['region'][2] for row in samples)
            bottom = max(row['region'][1] + row['region'][3] for row in samples)
            envelope = [left, top, right - left, bottom - top]
            cue['region'] = envelope
        observations.append({'cueId': cue['cueId'], 'startMs': start, 'endMs': end,
            'selectedRegion': list(job['crop']), 'samples': samples, 'windows': windows,
            'completeSampleGrid': complete and len(samples) >= 2, 'placementEnvelope': envelope,
            'association': 'selected-region-texture-lk-ransac-unqualified', 'qualityQualified': False})
        progress(folder, 'Tracking selected sign regions locally', (index + 1) / len(result['cues']))
    result['signMotionEvidence'] = observations
    result.setdefault('warnings', []).append(
        'Sign motion follows texture in the selected crop at 12 Hz, not recognized sign identity. '
        'Background motion may be mistaken for the sign. Cuts, weak matches and lost regions stop each path. '
        'Only complete sampled paths propose a fixed placement envelope; incomplete paths retain the selected region. '
        'Long cues restart matching every twelve seconds from the last observed region. '
        'Review the observations and source images before accepting. App captions do not animate along the path.')
    return result
