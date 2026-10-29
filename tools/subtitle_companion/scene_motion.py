"""Bounded, local feature-motion proposals. No identity or semantic tracking."""
from __future__ import annotations
import math
import os
import subprocess
import threading

WIDTH, HEIGHT, FPS = 640, 360, 12


def _frames(folder, cue):
    from bitmap_ocr import stop
    span = cue['endMs'] - cue['startMs']
    if not 0 < span <= 12000:
        raise ValueError('motion_cue_exceeds_twelve_seconds')
    command = [os.environ.get('PLEZY_FFMPEG', 'ffmpeg'), '-nostdin', '-hide_banner', '-loglevel', 'error',
        '-protocol_whitelist', 'file,pipe', '-format_whitelist', 'matroska,webm,mov,avi,mpegts,mpeg',
        '-threads', '2', '-filter_threads', '1', '-ss', str(cue['startMs'] / 1000),
        '-i', str(folder / 'input.media'), '-an', '-sn', '-t', str(span / 1000),
        '-vf', f'scale={WIDTH}:{HEIGHT},fps={FPS}:start_time=0', '-pix_fmt', 'gray', '-f', 'rawvideo', 'pipe:1']
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    timer = threading.Timer(90, stop, (process,)); timer.daemon = True; timer.start()
    count, bound = 0, WIDTH * HEIGHT
    try:
        while count < math.ceil(span * FPS / 1000):
            data = bytearray()
            while len(data) < bound:
                block = process.stdout.read(bound - len(data))
                if not block: break
                data.extend(block)
            if not data: break
            if len(data) != bound: raise ValueError('motion_frame_incomplete')
            yield cue['startMs'] + round(count * 1000 / FPS), data
            count += 1
        if count == 0: raise ValueError('motion_frames_unavailable')
        # The fixed output grid should cover the requested cue to within one
        # frame; a truncated decoder must not masquerade as a completed track.
        if count < max(1, math.floor(span * FPS / 1000) - 1):
            raise ValueError('motion_interval_incomplete')
    finally:
        timer.cancel(); stop(process); process.wait(); process.stdout.close()


def track_regions(folder, cue, boxes):
    """Track first-frame region texture at 12 Hz until an uncertainty gate fails.

    Returned envelopes are conservative placement proposals; the UI does not
    animate a caption along these paths or automatically accept model wording.
    Thresholds are heuristics, not calibrated probabilities or quality claims.
    """
    import cv2
    import numpy as np
    if len(boxes) > 12: raise ValueError('motion_region_limit')
    cv2.setNumThreads(2)
    cv2.ocl.setUseOpenCL(False)
    tracks, previous = [], None
    stream = _frames(folder, cue)
    status = 'completed-frame-grid'
    frames = 0
    def features(gray, box):
        left, top, width, height = box
        x, y = max(0, int(left * WIDTH)), max(0, int(top * HEIGHT))
        right, bottom = min(WIDTH, math.ceil((left + width) * WIDTH)), min(HEIGHT, math.ceil((top + height) * HEIGHT))
        mask = np.zeros((HEIGHT, WIDTH), dtype=np.uint8)
        mask[y:bottom, x:right] = 255
        points = cv2.goodFeaturesToTrack(gray, maxCorners=80, qualityLevel=.015, minDistance=4, mask=mask, blockSize=5)
        return points if points is not None and len(points) >= 8 else None
    try:
        for time_ms, raw in stream:
            gray = np.frombuffer(raw, dtype=np.uint8).reshape(HEIGHT, WIDTH)
            frames += 1
            if previous is None:
                for index, box in enumerate(boxes):
                    points = features(gray, box)
                    left, top, width, height = box
                    corners = np.asarray([[left*WIDTH, top*HEIGHT, 1], [(left+width)*WIDTH, top*HEIGHT, 1],
                        [left*WIDTH, (top+height)*HEIGHT, 1], [(left+width)*WIDTH, (top+height)*HEIGHT, 1]], dtype=np.float64)
                    tracks.append({'id': f'motion-{index+1}', 'box': list(box), 'points': points,
                        'corners': corners,
                        'samples': [{'timeMs': time_ms, 'region': list(box), 'matchedFeatures': 0}],
                        'stopReason': None if points is not None else 'insufficient-initial-texture'})
                previous = gray
                if not any(track['points'] is not None for track in tracks):
                    status = 'no-trackable-texture'; break
                continue
            # A cut/flash gate ends the paths; never associate people/objects
            # across it. No automatic reseeding after a failed correspondence.
            difference = float(np.mean(np.abs(gray.astype(np.int16) - previous.astype(np.int16))))
            if difference > 45:
                status = 'cut-or-flash-gate'
                for track in tracks:
                    if track['points'] is not None: track['stopReason'] = status
                break
            for track in tracks:
                points = track['points']
                if points is None: continue
                def retire(reason):
                    track['points'] = None; track['stopReason'] = reason
                following, good, _ = cv2.calcOpticalFlowPyrLK(previous, gray, points, None,
                    winSize=(21, 21), maxLevel=3, criteria=(cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 30, .01))
                if following is None or good is None or not np.isfinite(following).all():
                    retire('forward-flow-unavailable'); continue
                back, reverse, _ = cv2.calcOpticalFlowPyrLK(gray, previous, following, None,
                    winSize=(21, 21), maxLevel=3, criteria=(cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 30, .01))
                if back is None or reverse is None or not np.isfinite(back).all():
                    retire('reverse-flow-unavailable'); continue
                roundtrip = np.linalg.norm((back - points).reshape(-1, 2), axis=1)
                keep = (good.reshape(-1) == 1) & (reverse.reshape(-1) == 1) & (roundtrip <= 1.5)
                a, b = points.reshape(-1, 2)[keep], following.reshape(-1, 2)[keep]
                if len(a) < 8 or len(a) < len(points) * .6:
                    retire('insufficient-roundtrip-matches'); continue
                matrix, inliers = cv2.estimateAffinePartial2D(a, b, method=cv2.RANSAC,
                    ransacReprojThreshold=2, maxIters=1000, confidence=.99, refineIters=10)
                if matrix is None or inliers is None or not np.isfinite(matrix).all() or int(inliers.sum()) < max(8, len(a)*.6):
                    retire('inconsistent-region-motion'); continue
                scale = math.hypot(float(matrix[0, 0]), float(matrix[1, 0]))
                angle = abs(math.atan2(float(matrix[1, 0]), float(matrix[0, 0])))
                if not .90 <= scale <= 1.10 or angle > .12 or float(np.linalg.norm(matrix[:, 2])) > 60:
                    retire('motion-bound-exceeded'); continue
                moved = track['corners'] @ matrix.T
                x0, y0 = np.min(moved, axis=0); x1, y1 = np.max(moved, axis=0)
                if x0 < 0 or y0 < 0 or x1 > WIDTH or y1 > HEIGHT or x1-x0 < 4 or y1-y0 < 4:
                    retire('region-left-frame'); continue
                box = [float(x0/WIDTH), float(y0/HEIGHT), float((x1-x0)/WIDTH), float((y1-y0)/HEIGHT)]
                track['box'] = box
                track['corners'] = np.column_stack((moved, np.ones(4)))
                track['points'] = b[inliers.reshape(-1) == 1].astype(np.float32).reshape(-1, 1, 2)
                track['samples'].append({'timeMs': time_ms, 'region': box, 'matchedFeatures': int(inliers.sum()),
                    'maximumRoundtripPixels': float(roundtrip[keep].max())})
            previous = gray
            if not any(track['points'] is not None for track in tracks): status = 'all-correspondences-ended'; break
    finally:
        stream.close()
    proposals = []
    for track in tracks:
        samples = track['samples']
        # A single seed alone is already available in the scene evidence. Do
        # not label it tracked when no subsequent observation was accepted.
        if len(samples) < 2: continue
        left = min(row['region'][0] for row in samples); top = min(row['region'][1] for row in samples)
        right = max(row['region'][0] + row['region'][2] for row in samples)
        bottom = max(row['region'][1] + row['region'][3] for row in samples)
        proposals.append({'id': track['id'], 'samples': samples, 'envelope': [left, top, right-left, bottom-top],
            'association': 'forward-backward-lk-ransac-unqualified', 'stopReason': track['stopReason'] or status})
    return {'tracks': proposals, 'framesObserved': frames, 'gridFps': FPS, 'status': status, 'opencv': cv2.__version__,
        'qualityQualified': False, 'frameClock': 'ffmpeg-resampled-cue-grid', 'startMs': cue['startMs'], 'endMs': cue['endMs']}
