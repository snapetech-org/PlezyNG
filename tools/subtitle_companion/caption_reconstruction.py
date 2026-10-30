"""Explicit bounded video derivative with a viewer-specified caption mask.

Spatial inpainting invents missing pixels. It cannot recover the original image
behind burned captions. No model downloads, source edits or playback replacement.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import subprocess
import threading
import zipfile

from bitmap_ocr import stop

FORMATS = 'matroska,webm,mov,avi,mpegts,mpeg'
MAX_ARTIFACT = 32 * 1024**2
NAME = 'caption-reconstruction.zip'
FPS = 12


def validate(value):
    cues = value.get('cues', [])
    if (value.get('reconstructionConsent') is not True or not 0 < len(cues) <= 120 or
            value.get('itemTimeline', False) or value.get('timelineOffsetMs', 0) or value.get('preprocess', False)):
        raise ValueError('reconstruction_requires_explicit_consent_file_clock_cues')
    start, end = min(c['startMs'] for c in cues), max(c['endMs'] for c in cues)
    if not 500 <= end - start <= 30000 or end > 3600000:
        raise ValueError('reconstruction_requires_half_to_thirty_second_interval')
    crop = value.get('crop')
    if (not isinstance(crop, list) or len(crop) != 4 or
            any(type(n) not in (int, float) or not math.isfinite(n) or not 0 <= n <= 1 for n in crop)):
        raise ValueError('invalid_reconstruction_mask')
    x, y, w, h = crop
    if w < .05 or h < .05 or w*h > .2 or x+w > 1 or y+h > 1:
        raise ValueError('reconstruction_mask_exceeds_twenty_percent')
    return start, end


def _probe(path):
    process = subprocess.Popen([os.environ.get('PLEZY_FFPROBE', 'ffprobe'), '-v', 'error',
        '-protocol_whitelist', 'file,pipe', '-format_whitelist', FORMATS,
        '-show_entries', 'stream=index,codec_type,width,height,pix_fmt,sample_aspect_ratio,color_space,color_transfer,color_primaries:stream_tags=rotate:stream_side_data=rotation:format=duration',
        '-of', 'json', str(path)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    timer = threading.Timer(30, stop, (process,)); timer.daemon = True; timer.start()
    try:
        raw = process.stdout.read(65537)
        if len(raw) > 65536 or process.wait(timeout=5): raise ValueError('reconstruction_probe_failed')
        return json.loads(raw)
    finally:
        timer.cancel(); stop(process); process.wait(); process.stdout.close()


def _stamp(ms):
    hours, ms = divmod(ms, 3600000); minutes, ms = divmod(ms, 60000); seconds, ms = divmod(ms, 1000)
    return f'{hours:02}:{minutes:02}:{seconds:02},{ms:03}'


def run(folder, job, progress):
    import cv2
    import numpy as np
    cv2.setNumThreads(2); cv2.ocl.setUseOpenCL(False)
    start, end = validate(job)
    source = folder / 'input.media'
    info = _probe(source)
    streams = info.get('streams', [])
    if len(streams) > 128: raise ValueError('reconstruction_stream_limit')
    videos = [s for s in streams if s.get('codec_type') == 'video']
    audios = [s for s in streams if s.get('codec_type') == 'audio']
    if not videos: raise ValueError('reconstruction_video_required')
    video = videos[0]
    width, height = video.get('width', 0), video.get('height', 0)
    if not 32 <= width <= 4096 or not 32 <= height <= 2160:
        raise ValueError('reconstruction_source_dimensions_unsupported')
    # Refuse unknown/HDR/high-bit-depth/rotated/anamorphic sources instead of
    # silently tone mapping or applying the mask in the wrong coordinate space.
    if (video.get('pix_fmt') not in {'yuv420p', 'yuv422p', 'yuv444p', 'nv12'} or
            any(video.get(k) != 'bt709' for k in ('color_space', 'color_transfer', 'color_primaries')) or
            video.get('sample_aspect_ratio') not in {'1:1', '1/1'} or
            float(video.get('tags', {}).get('rotate', 0)) % 360 or
            any(float(s.get('rotation', 0)) % 360 for s in video.get('side_data_list', []))):
        raise ValueError('reconstruction_requires_unrotated_square_pixel_eight_bit_bt709')
    duration = float(info.get('format', {}).get('duration', 0))
    if not math.isfinite(duration) or duration * 1000 < end:
        raise ValueError('reconstruction_interval_exceeds_media')
    track = job.get('audioTrack', 0)
    if audios and not 0 <= track < len(audios): raise ValueError('reconstruction_audio_track_missing')
    ratio = min(1, 960 / width, 540 / height)
    width, height = max(2, int(width * ratio) // 2 * 2), max(2, int(height * ratio) // 2 * 2)
    x, y, w, h = job['crop']
    mask = np.zeros((height, width), dtype=np.uint8)
    mask[int(y*height):min(height, math.ceil((y+h)*height)), int(x*width):min(width, math.ceil((x+w)*width))] = 255
    if int(np.count_nonzero(mask)) > width*height*.21:
        raise ValueError('reconstruction_pixel_mask_limit')
    temporary = folder / 'reconstruction-video.part.mp4'
    target = folder / 'reconstruction-preview.mp4'
    archive = folder / NAME
    for path in (temporary, target, archive):
        if path.is_symlink(): raise ValueError('invalid_reconstruction_path')
        path.unlink(missing_ok=True)
    ffmpeg = os.environ.get('PLEZY_FFMPEG', 'ffmpeg')
    span = (end - start) / 1000
    common = [ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error', '-threads', '2', '-filter_threads', '1']
    decoder = subprocess.Popen(common + ['-protocol_whitelist', 'file,pipe', '-format_whitelist', FORMATS,
        '-ss', str(start / 1000), '-noautorotate', '-i', str(source), '-map', '0:v:0', '-an', '-sn',
        '-t', str(span), '-vf', f'scale={width}:{height},setsar=1,fps={FPS}:start_time=0',
        '-pix_fmt', 'bgr24', '-f', 'rawvideo', 'pipe:1'],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    encoder = None
    timer = None
    images, frame_count, altered_count = {}, 0, 0
    try:
        encoder = subprocess.Popen(common + ['-y', '-f', 'rawvideo', '-pix_fmt', 'bgr24',
            '-s', f'{width}x{height}', '-r', str(FPS), '-i', 'pipe:0', '-an', '-c:v', 'mpeg4', '-q:v', '3',
            '-threads', '2', '-vf', 'scale=out_color_matrix=bt709:out_range=tv', '-pix_fmt', 'yuv420p', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709',
            '-fs', str(28 * 1024**2), '-movflags', '+faststart', str(temporary)],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def expire():
            stop(decoder); stop(encoder)
        timer = threading.Timer(180, expire); timer.daemon = True; timer.start()
        count = math.ceil(span * FPS)
        bound = width * height * 3
        while True:
            data = bytearray()
            while len(data) < bound:
                block = decoder.stdout.read(bound - len(data))
                if not block: break
                data.extend(block)
            if not data: break
            if len(data) != bound or frame_count >= count + 1:
                raise ValueError('reconstruction_frame_limit')
            at = start + round(frame_count * 1000 / FPS)
            frame = np.frombuffer(data, dtype=np.uint8).reshape(height, width, 3)
            active = any(c['startMs'] <= at < c['endMs'] for c in job['cues'])
            # Navier-Stokes spatial fill is deliberately independent per frame.
            # It is not a generative model or temporally reconstructed ground truth.
            output = cv2.inpaint(frame, mask, 3, cv2.INPAINT_NS) if active else frame
            if active:
                altered_count += 1
                if not images:
                    for name, image in [('before.png', frame), ('after.png', output), ('mask.png', mask)]:
                        ok, encoded = cv2.imencode('.png', image)
                        if not ok or len(encoded) > 4*1024**2: raise ValueError('reconstruction_image_limit')
                        images[name] = encoded.tobytes()
            encoder.stdin.write(output.tobytes())
            frame_count += 1
            progress(folder, 'Creating a separate masked video preview', min(1, frame_count / count))
        if frame_count < max(1, math.floor(span * FPS) - 1) or not altered_count or decoder.wait(timeout=5):
            raise ValueError('reconstruction_frame_grid_incomplete')
        encoder.stdin.close()
        if encoder.wait(timeout=30): raise ValueError('reconstruction_encode_failed')
        # The file-size cap may stop an encoder successfully; verify its output
        # duration before it can masquerade as a complete reviewed derivative.
        encoded_info = _probe(temporary)
        encoded_duration = float(encoded_info.get('format', {}).get('duration', 0))
        if not math.isfinite(encoded_duration) or abs(encoded_duration - frame_count/FPS) > 2/FPS:
            raise ValueError('reconstruction_output_truncated')
        if audios:
            command = common + ['-y', '-protocol_whitelist', 'file,pipe', '-i', str(temporary),
                '-protocol_whitelist', 'file,pipe', '-format_whitelist', FORMATS, '-ss', str(start/1000), '-i', str(source),
                '-map', '0:v:0', '-map', f'1:a:{track}', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
                '-ac', '2', '-ar', '48000', '-t', str(frame_count/FPS), '-map_metadata', '-1', '-map_chapters', '-1',
                '-fs', str(29*1024**2), '-movflags', '+faststart', str(target)]
            if subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, timeout=60).returncode:
                raise ValueError('reconstruction_audio_mux_failed')
        else:
            temporary.replace(target)
        final_duration = float(_probe(target).get('format', {}).get('duration', 0))
        if not math.isfinite(final_duration) or abs(final_duration - frame_count/FPS) > .25:
            raise ValueError('reconstruction_final_output_truncated')
        srt = '\n\n'.join(f"{index+1}\n{_stamp(cue['startMs']-start)} --> {_stamp(cue['endMs']-start)}\n{cue['text']}"
            for index, cue in enumerate(job['cues'])) + '\n'
        report = {'schema': 'plezyng.caption-reconstruction.v1', 'inputSha256': job['audioDigest'],
            'sourceStartMs': start, 'sourceEndMs': end, 'clipTimeOriginMs': start,
            'mask': job['crop'], 'maskActiveIntervals': [[c['startMs'], c['endMs']] for c in job['cues']],
            'outputWidth': width, 'outputHeight': height, 'outputFps': FPS, 'outputFrames': frame_count,
            'alteredFrames': altered_count, 'method': 'opencv-navier-stokes-spatial-fill', 'opencv': cv2.__version__,
            'qualityQualified': False, 'originalBackgroundRecovered': False,
            'audio': {'sourceOrdinal': track, 'output': 'AAC-stereo-48kHz'} if audios else None,
            'captionClock': 'clip-relative', 'sourceCueIds': [c['cueId'] for c in job['cues']]}
        content = {'captions.srt': srt.encode(), 'report.json': json.dumps(report, ensure_ascii=False, allow_nan=False).encode(), **images}
        if target.stat().st_size + sum(map(len, content.values())) > MAX_ARTIFACT - 4096:
            raise ValueError('reconstruction_artifact_limit')
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as bundle:
            bundle.write(target, 'preview.mp4')
            for name, raw in content.items(): bundle.writestr(name, raw)
        if archive.stat().st_size > MAX_ARTIFACT: raise ValueError('reconstruction_artifact_limit')
        return {'cues': job['cues'], 'wordTimings': [], 'language': job.get('language') or 'unknown', 'durationMs': end,
            'reconstructionEvidence': report,
            'artifacts': [{'name': NAME, 'mime': 'application/zip', 'bytes': archive.stat().st_size,
                           'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}],
            'warnings': ['Spatial fill invents pixels and can smear or flicker; it does not recover the original background. '
                'Review before.png, after.png, mask.png and the full preview before using this derivative.',
                'Separate at-most-960×540, 12 Hz, 8-bit BT.709 preview with lossy MPEG-4 video and optional AAC stereo. '
                'The selected rectangle is filled only during supplied cue intervals. Captions are a separate clip-clock SRT. '
                'The original media and current playback remain unchanged.']}
    finally:
        if timer is not None: timer.cancel()
        stop(decoder); decoder.wait(); decoder.stdout.close()
        if encoder is not None:
            stop(encoder); encoder.wait()
            if encoder.stdin is not None and not encoder.stdin.closed: encoder.stdin.close()
        temporary.unlink(missing_ok=True); target.unlink(missing_ok=True)
