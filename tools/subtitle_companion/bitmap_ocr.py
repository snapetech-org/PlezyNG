"""Bounded bitmap decoding/OCR with immutable, content-addressed PNG evidence.

The native helper exposes FFmpeg subtitle palettes/strides directly. PyAV's
bitmap plane view does not expose the required palette/stride contract in the
audited version, so no guessed colors or unsafe plane reads are used here.
"""
from __future__ import annotations

import csv
import hashlib
import io
import math
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import threading
import zipfile
import zlib

MAX_EVIDENCE = 32 * 1024**2
MAX_IMAGE = 4 * 1024**2
MAX_PIXELS = 8 * 1024**2


def prepare_input(folder):
    source = folder / "input.media"
    if not zipfile.is_zipfile(source):
        return source
    stage = folder / "bitmap_input"
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(mode=0o700)
    with zipfile.ZipFile(source) as archive:
        entries = archive.infolist()
        if len(entries) != 2:
            raise ValueError("vobsub_zip_requires_one_idx_sub_pair")
        names = {}
        for entry in entries:
            name = entry.filename
            suffix = Path(name).suffix.lower()
            if (not re.fullmatch(r"[\w .-]{1,200}", name) or name.startswith(".") or
                    "/" in name or "\\" in name or suffix not in {".idx", ".sub"} or suffix in names or
                    entry.is_dir() or entry.flag_bits & 1 or (entry.external_attr >> 16) & 0o170000 == 0o120000 or
                    entry.compress_type not in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}):
                raise ValueError("invalid_vobsub_zip_entry")
            maximum = 1024**2 if suffix == ".idx" else 256 * 1024**2
            if not 0 < entry.file_size <= maximum:
                raise ValueError("vobsub_pair_size_limit")
            names[suffix] = entry
        if set(names) != {".idx", ".sub"} or Path(names[".idx"].filename).stem.casefold() != Path(names[".sub"].filename).stem.casefold():
            raise ValueError("vobsub_pair_names_do_not_match")
        for suffix, entry in names.items():
            count = 0
            with archive.open(entry) as incoming, (stage / f"captions{suffix}").open("wb") as output:
                for block in iter(lambda: incoming.read(65536), b""):
                    count += len(block)
                    if count > entry.file_size:
                        raise ValueError("vobsub_pair_size_mismatch")
                    output.write(block)
            if count != entry.file_size:
                raise ValueError("vobsub_pair_size_mismatch")
        if not (stage / "captions.idx").read_bytes().lstrip().startswith(b"# VobSub index file"):
            raise ValueError("invalid_vobsub_index")
    return stage / "captions.idx"


def png(width, height, data, channels):
    def chunk(kind, value):
        return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", zlib.crc32(kind + value) & 0xffffffff)
    compressor = zlib.compressobj(6)
    compressed = bytearray()
    stride = width * channels
    for row in range(height):
        compressed.extend(compressor.compress(b"\0" + data[row * stride:(row + 1) * stride]))
        if len(compressed) > MAX_IMAGE:
            raise ValueError("bitmap_image_size_limit")
    compressed.extend(compressor.flush())
    output = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6 if channels == 4 else 0, 0, 0, 0)) +
              chunk(b"IDAT", bytes(compressed)) + chunk(b"IEND", b""))
    if len(output) > MAX_IMAGE:
        raise ValueError("bitmap_image_size_limit")
    return output


def stop(process):
    try:
        if process.poll() is None:
            process.kill()
    except OSError:
        pass


def read_text(path):
    language = os.environ.get("PLEZY_TESSERACT_LANGUAGE", "eng")
    if not re.fullmatch(r"[A-Za-z0-9_+.-]{1,120}", language):
        raise ValueError("invalid_ocr_model_language")
    process = subprocess.Popen(["tesseract", str(path), "stdout", "-l", language, "--psm", "6", "tsv"],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    timer = threading.Timer(60, stop, (process,))
    timer.daemon = True
    timer.start()
    try:
        output = process.stdout.read(1024**2 + 1)
        if len(output) > 1024**2:
            raise ValueError("ocr_text_limit")
        if process.wait(timeout=5):
            raise ValueError("ocr_failed_or_timed_out")
    finally:
        timer.cancel()
        stop(process)
        process.wait()
        process.stdout.close()
    lines, scores = {}, []
    for row in csv.DictReader(io.StringIO(output.decode("utf-8", errors="strict")), delimiter="\t"):
        text = row.get("text", "").strip()
        score = float(row.get("conf", "-1"))
        if text and math.isfinite(score) and 0 <= score <= 100:
            key = (row.get("block_num"), row.get("par_num"), row.get("line_num"))
            lines.setdefault(key, []).append(text)
            scores.append(score / 100)
    text = "\n".join(" ".join(line) for line in lines.values())
    if len(text) > 4000:
        raise ValueError("ocr_cue_text_limit")
    return text, sum(scores) / len(scores) if scores else 0.0


def run(folder, job, progress):
    source = prepare_input(folder)
    evidence = folder / "evidence"
    shutil.rmtree(evidence, ignore_errors=True)
    evidence.mkdir(mode=0o700)
    process = subprocess.Popen([os.environ.get("PLEZY_SUBTITLE_DECODER", "plezy-subtitle-decode"), str(source), str(job["subtitleTrack"])],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    timer = threading.Timer(4 * 3600, stop, (process,))
    timer.daemon = True
    timer.start()
    cues, images, uncertain, stored = [], [], [], set()
    evidence_bytes, last_start, displays = 0, -1, 0
    tail_guessed = False

    def read(size, eof=False):
        data = bytearray()
        while len(data) < size:
            block = process.stdout.read(size - len(data))
            if not block:
                if eof and not data:
                    return None
                raise ValueError("truncated_bitmap_decoder_output")
            data.extend(block)
        return bytes(data)

    def finish(display, next_start=None):
        nonlocal evidence_bytes, tail_guessed
        start, declared_end, rectangles = display
        if not rectangles:
            return
        end = declared_end
        if next_start is not None:
            end = next_start if end == -1 else min(end, next_start)
        elif end == -1:
            end = min(3600000, start + job["finalBitmapDurationMs"])
            tail_guessed = True
        if end <= start:
            return  # Same-time palette/display update supersedes its earlier version.
        for x, y, width, height, forced, rgba in rectangles:
            original = png(width, height, rgba, 4)
            digest = hashlib.sha256(original).hexdigest()
            if digest not in stored:
                if evidence_bytes + len(original) > MAX_EVIDENCE:
                    raise ValueError("bitmap_evidence_storage_limit")
                (evidence / f"{digest}.png").write_bytes(original)
                stored.add(digest)
                evidence_bytes += len(original)
            # Normalize only the OCR input: alpha-composite on black and invert
            # to dark letters on white. The evidence PNG retains original RGBA.
            gray = bytearray(width * height)
            for pixel in range(width * height):
                r, g, b, alpha = rgba[pixel * 4:pixel * 4 + 4]
                gray[pixel] = 255 - ((r * 77 + g * 150 + b * 29) * alpha // (256 * 255))
            input_png = folder / "ocr_input.png"
            input_png.write_bytes(png(width, height, gray, 1))
            text, score = read_text(input_png)
            needs_review = not text or score < 0.65
            if not text:
                text = "[OCR text requires review]"
            identifier = hashlib.sha256(f"{job['audioDigest']}:{start}:{end}:{x}:{y}:{len(cues)}:{digest}".encode()).hexdigest()
            cues.append({"cueId": identifier, "index": len(cues) + 1, "startMs": start, "endMs": end,
                         "text": text, "ocrConfidence": score, "requiresReview": needs_review})
            images.append({"cueId": identifier, "sha256": digest, "bytes": len(original), "width": width, "height": height,
                           "x": x, "y": y, "forced": bool(forced), "startMs": start, "endMs": end, "confidence": score,
                           "requiresReview": needs_review})
            if needs_review:
                uncertain.append(identifier)
            if len(cues) > 50000:
                raise ValueError("caption_limit")
        progress(folder, "Reading bitmap caption images", min(0.99, end / 3600000))

    active = None
    try:
        if read(8) != b"PLZYBMP1":
            raise ValueError("unsupported_bitmap_decoder_protocol")
        while (header := read(20, eof=True)) is not None:
            start, end, count = struct.unpack("<qqI", header)
            displays += 1
            if not 0 <= start <= 3600000 or start < last_start or count > 32 or displays > 50000 or (end != -1 and not start < end <= 3600000):
                raise ValueError("invalid_bitmap_display")
            last_start = start
            rectangles, pixels = [], 0
            for _ in range(count):
                x, y, width, height, forced, size = struct.unpack("<iiIIII", read(24))
                pixels += width * height
                if (not 0 <= x <= 8192 or not 0 <= y <= 8192 or not 0 < width <= 4096 or not 0 < height <= 2160 or
                        pixels > MAX_PIXELS or size != width * height * 4 or forced not in (0, 1)):
                    raise ValueError("invalid_bitmap_rectangle")
                rectangles.append((x, y, width, height, forced, read(size)))
            if active is not None:
                finish(active, start)
            active = (start, end, rectangles)
        if process.wait(timeout=30):
            raise ValueError("bitmap_decode_failed")
        if active is not None:
            finish(active)
    finally:
        timer.cancel()
        stop(process)
        process.wait()
        process.stdout.close()
        (folder / "ocr_input.png").unlink(missing_ok=True)
        shutil.rmtree(folder / "bitmap_input", ignore_errors=True)
    return {"cues": cues, "wordTimings": [], "images": images, "language": job.get("language") or "unknown",
            "durationMs": max((c["endMs"] for c in cues), default=0), "uncertainCueIds": uncertain,
            "ocrModelLanguage": os.environ.get("PLEZY_TESSERACT_LANGUAGE", "eng"),
            "warnings": [f"{len(uncertain)} bitmap cues have uncertain OCR; unreadable text has an explicit review placeholder.",
                         "PGS/VobSub timing comes from decoded display events. OCR scores are uncalibrated. Review the original RGBA images before accepting text.",
                         "Rectangle coordinates and forced flags are preserved in image provenance; SRT flattens their screen positions.",
                         f"The final bitmap lacked a clear/end event; its duration uses the selected {job['finalBitmapDurationMs']} ms." if tail_guessed else "All bitmap ends came from decoder timing or subsequent display events."]}
