#!/usr/bin/env python3
"""Bounded karaoke preparation worker. No arbitrary commands or network sources.

Inputs are copied by the authenticated server into a private job directory.
Models must already be provisioned; generated lyrics/notes remain unreviewed.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import wave

VERSION = "plezy-karaoke-worker-1"
MEDIA_FORMATS = "aac,flac,mp3,mov,matroska,webm,ogg,wav"


def run(args: list[str], *, capture=False):
    result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                            stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise RuntimeError(f"{Path(args[0]).name} failed: {result.stderr[-3000:].decode(errors='replace')}")
    return result.stdout if capture else None


def ffmpeg(inputs, filters, output, extra=()):
    args = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-threads", "2"]
    for source in inputs:
        args += ["-protocol_whitelist", "file,pipe", "-format_whitelist", MEDIA_FORMATS, "-i", str(source)]
    args += list(filters) + list(extra) + [str(output)]
    run(args)


def duration(source: Path) -> float:
    result = json.loads(run(["ffprobe", "-v", "error", "-protocol_whitelist", "file,pipe", "-format_whitelist", MEDIA_FORMATS,
                             "-show_entries", "format=duration", "-of", "json", str(source)], capture=True))
    value = float(result["format"]["duration"])
    if not math.isfinite(value) or not 0 < value <= 1800:
        raise ValueError("Preparation accepts media up to 30 minutes")
    return value


def number(params, key, default, low, high):
    value = float(params.get(key, default))
    if not math.isfinite(value) or not low <= value <= high:
        raise ValueError(f"{key} is out of range")
    return value


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, allow_nan=False), encoding="utf-8")


def waveform(source, out):
    pcm = out / "analysis.wav"
    ffmpeg([source], ["-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le"], pcm)
    import array
    with wave.open(str(pcm), "rb") as reader:
        peaks = []
        while data := reader.readframes(512):
            samples = array.array("h", data)
            if sys.byteorder != "little": samples.byteswap()
            peaks.append([min(samples) / 32768, max(samples) / 32768])
    pcm.unlink()
    write_json(out / "waveform.json", {"sampleRate": 16000, "framesPerPeak": 512, "peaks": peaks})


def separate(source, out, params, models):
    if not models or not models.is_dir(): raise ValueError("Provision approved local Demucs model files first")
    # The repository is explicitly local; no implicit model download.
    run([sys.executable, "-m", "demucs.separate", "--repo", str(models), "-n", "htdemucs", "-d", "cpu",
         "--two-stems", "vocals", "--segment", "7", "--shifts", "0", "-j", "1", "-o", str(out / "work"), str(source)])
    vocals = list((out / "work").rglob("vocals.wav"))
    backing = list((out / "work").rglob("no_vocals.wav"))
    if len(vocals) != 1 or len(backing) != 1: raise ValueError("Separation produced an unexpected stem set")
    for src, name in [(vocals[0], "lead.wav"), (backing[0], "instrumental.wav")]:
        ffmpeg([src], ["-ac", "2", "-ar", "48000", "-c:a", "pcm_s24le"], out / name)
    import shutil
    shutil.rmtree(out / "work")


def align(source, out, params, models):
    lyrics = params.get("lyrics", "")
    if not isinstance(lyrics, str) or not 0 < len(lyrics) <= 50000: raise ValueError("Supply approved lyrics, up to 50,000 characters")
    language = params.get("language", "en")
    if not isinstance(language, str) or len(language) > 16: raise ValueError("Invalid language")
    if not models or not models.is_dir(): raise ValueError("Provision a local alignment model first")
    import whisperx
    audio = whisperx.load_audio(str(source))
    model, metadata = whisperx.load_align_model(language_code=language, device="cpu", model_dir=str(models), model_cache_only=True)
    result = whisperx.align([{"start": 0, "end": len(audio) / 16000, "text": lyrics}], model, metadata, audio, "cpu", return_char_alignments=True)
    words = iter(result.get("word_segments", []))
    lines, warnings = [], []
    for raw in lyrics.splitlines():
        spans = []
        # Match in source order; repeated choruses are never deduplicated.
        for token in raw.split():
            word = next(words, {})
            if word.get("start") is None or word.get("end") is None:
                warnings.append(f"Unaligned token: {token}")
                continue
            spans.append({"text": token + " ", "startMs": round(word["start"] * 1000), "endMs": round(word["end"] * 1000),
                          "unit": "word", "confidence": word.get("score")})
        line = {"text": raw, "spans": spans}
        if spans: line.update(startMs=spans[0]["startMs"], endMs=spans[-1]["endMs"])
        lines.append(line)
    write_json(out / "lyrics.json", {"synced": any("startMs" in l for l in lines), "lines": lines})
    write_json(out / "review.json", {"reviewRequired": True, "warnings": warnings,
        "method": "CTC forced alignment on supplied vocal audio; singing timing requires audition", "language": language})


def analyze(source, out, params):
    import librosa
    import numpy as np
    audio, sr = librosa.load(str(source), sr=22050, mono=True)
    tempo, _ = librosa.beat.beat_track(y=audio, sr=sr)
    chroma = librosa.feature.chroma_stft(y=audio, sr=sr, hop_length=512)
    energy = chroma.mean(axis=1)
    major = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
    minor = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
    names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    candidates = []
    for mode, template in [("major", major), ("minor", minor)]:
        for root in range(12):
            corr = float(np.corrcoef(energy, np.roll(template, root))[0, 1])
            candidates.append((corr if math.isfinite(corr) else 0, names[root] + " " + mode))
    candidates.sort(reverse=True)
    chords = []
    for start in range(0, chroma.shape[1], 22):
        frame = chroma[:, start:start+22].mean(axis=1)
        choices = [(float(sum(frame[(root+i) % 12] for i in intervals)), names[root]+suffix)
                   for root in range(12) for intervals, suffix in [((0, 4, 7), ""), ((0, 3, 7), "m")]]
        value, chord = max(choices)
        chords.append({"startMs": round(start*512/sr*1000), "chord": chord, "confidence": min(1, value/max(.001, float(frame.sum())))})
    write_json(out / "analysis.json", {"estimated": True, "bpm": float(np.asarray(tempo).flat[0]), "key": candidates[0][1],
        "keyConfidence": max(0, candidates[0][0]-candidates[1][0]), "chords": chords})
    waveform(source, out)


def reference(source, out, params):
    if params.get("isolatedVocal") is not True: raise ValueError("Pitch proposals require an isolated vocal, never a full mix")
    import librosa
    audio, sr = librosa.load(str(source), sr=16000, mono=True)
    pitches, voiced, probabilities = librosa.pyin(audio, fmin=65, fmax=1200, sr=sr, frame_length=1024, hop_length=256)
    notes, current = [], None
    for i, (pitch, is_voiced, confidence) in enumerate(zip(pitches, voiced, probabilities)):
        midi = round(69+12*math.log2(float(pitch)/440)) if is_voiced and confidence >= .8 and math.isfinite(pitch) else None
        at = round(i*256/sr*1000)
        if current is not None and midi != current["midi"]:
            current["endMs"] = at
            if at-current["startMs"] >= 80: notes.append(current)
            current = None
        if midi is not None and current is None:
            current = {"startMs": at, "endMs": at+16, "midi": midi, "part": "1", "text": "", "freestyle": False, "golden": False}
    if current:
        current["endMs"] = round(len(audio)/sr*1000)
        if current["endMs"] > current["startMs"]: notes.append(current)
    write_json(out / "notes.json", {"notes": notes, "reviewRequired": True, "method": "pYIN proposals from isolated vocal"})


def render(inputs, out, params):
    if len(inputs) < 2: raise ValueError("Rendering needs backing and dry vocal assets")
    key = number(params, "key", 0, -12, 12)
    tempo = number(params, "tempo", 1, .5, 2)
    start = number(params, "sourceStartMs", 0, 0, 1800000)/1000
    offset = number(params, "inputOffsetMs", 0, -2000, 2000)/1000
    trim = number(params, "trimStartMs", 0, 0, 1800000)/1000
    length = number(params, "durationMs", duration(inputs[1])*1000, 100, 1800000)/1000
    backing = number(params, "backingGain", .7, 0, 2)
    vocal = number(params, "vocalGain", 1, 0, 2)
    wet = number(params, "echoWet", 0, 0, .6)
    gate = number(params, "gate", 0, 0, .2)
    voice_filters = f"atrim=start={max(0,trim+offset):.6f}:duration={length:.6f},asetpts=PTS-STARTPTS,volume={vocal:.5f}"
    if offset+trim < 0: voice_filters += f",adelay={round(-(offset+trim)*1000)}:all=1"
    if gate > 0: voice_filters += f",agate=threshold={gate:.5f}"
    voice_filters += ",acompressor=threshold=0.25:ratio=3:attack=10:release=100"
    if wet > 0: voice_filters += f",aecho=0.8:0.9:120:{wet:.4f}"
    timeline = params.get("timeline", [])
    if not isinstance(timeline, list) or len(timeline) > 200: raise ValueError("Take timeline exceeds segment limit")
    sample_rate = number(params, "sampleRate", 48000, 48000, 48000)
    take_duration = duration(inputs[1])
    length = min(length, take_duration-trim)
    if length <= 0: raise ValueError("Trim starts after the take ends")
    points = [{"frame": 0, "sourceMs": start*1000, "key": key, "tempo": tempo}]
    for point in timeline:
        frame = number(point, "frame", 0, 0, take_duration*sample_rate)
        if frame < points[-1]["frame"]: raise ValueError("Take timeline is not ordered")
        normalized = {"frame": frame, "sourceMs": number(point, "sourceMs", 0, 0, 1800000),
                      "key": number(point, "key", key, -12, 12), "tempo": number(point, "tempo", tempo, .5, 2)}
        if frame == points[-1]["frame"]: points[-1] = normalized
        else: points.append(normalized)
    segments = []
    for i, point in enumerate(points):
        original_start = point["frame"]/sample_rate
        left = max(trim, original_start)
        right = min(trim+length, points[i+1]["frame"]/sample_rate if i+1 < len(points) else take_duration)
        if right > left:
            segments.append((left, right, point["sourceMs"]/1000+(left-original_start)*point["tempo"], point["tempo"], point["key"]))
    if not segments: raise ValueError("No renderable timeline segments")
    chains = [f"[0:a]asplit={len(segments)}"+"".join(f"[input{i}]" for i in range(len(segments)))]
    for i, (left, right, source, speed, transposition) in enumerate(segments):
        seconds = right-left
        chains.append(f"[input{i}]atrim=start={source:.6f}:duration={seconds*speed:.6f},asetpts=PTS-STARTPTS,"
                      f"rubberband=tempo={speed:.6f}:pitch={2**(transposition/12):.8f},apad,atrim=duration={seconds:.6f},"
                      f"afade=t=in:d=0.015,afade=t=out:st={max(0,seconds-.015):.6f}:d=0.015[segment{i}]")
    chains.append("".join(f"[segment{i}]" for i in range(len(segments)))+f"concat=n={len(segments)}:v=0:a=1,volume={backing:.5f}[back]")
    chains += [f"[1:a]{voice_filters}[voice]", "[back][voice]amix=inputs=2:duration=shortest:normalize=0,alimiter=limit=0.95:level=0[mix]"]
    graph = ";".join(chains)
    video = params.get("video") is True
    filters = ["-filter_complex", graph, "-map", "[mix]", "-t", str(length)]
    if video:
        if len(inputs) < 3: raise ValueError("Video export needs an approved camera/video asset")
        filters += ["-map", "2:v:0", "-vf", f"trim=start={trim:.6f},setpts=PTS-STARTPTS,scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2",
                    "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", "-movflags", "+faststart"]
    else: filters += ["-c:a", "pcm_s24le"]
    ffmpeg(inputs, filters, out / ("performance.mp4" if video else "performance.wav"))
    write_json(out / "recipe.json", {"schema": 1, "recipe": params, "dryPreserved": True, "assisted": wet > 0})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("job", type=Path)
    parser.add_argument("--models", type=Path)
    parser.add_argument("--soundfont", type=Path)
    args = parser.parse_args()
    job = args.job.resolve()
    request = json.loads((job / "request.json").read_text())
    out = job / "output"; out.mkdir(exist_ok=True)
    inputs = [job / f"input-{i}" for i in range(len(request["assets"]))]
    params = request.get("params", {})
    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", OMP_NUM_THREADS="2", MKL_NUM_THREADS="2")
    kind = request["kind"]
    if kind != "midi": duration(inputs[0])
    if kind == "waveform": waveform(inputs[0], out)
    elif kind == "separate": separate(inputs[0], out, params, args.models)
    elif kind == "align": align(inputs[0], out, params, args.models)
    elif kind == "analyze": analyze(inputs[0], out, params)
    elif kind == "reference": reference(inputs[0], out, params)
    elif kind == "render": render(inputs, out, params)
    elif kind == "midi":
        if not args.soundfont or not args.soundfont.is_file(): raise ValueError("Configure an approved local soundfont first")
        run(["fluidsynth", "-ni", "-T", "wav", "-F", str(out / "instrumental.wav"), "-r", "48000", str(args.soundfont), str(inputs[0])])
    else: raise ValueError("Unsupported preparation operation")
    files = []
    for file in out.iterdir():
        if file.is_file():
            digest = hashlib.file_digest(file.open("rb"), "sha256").hexdigest()
            files.append({"name": file.name, "bytes": file.stat().st_size, "sha256": digest})
    versions = {}
    for name in ["demucs", "whisperx", "librosa", "torch"]:
        try: versions[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError: pass
    write_json(job / "result.json", {"schema": 1, "worker": VERSION, "kind": kind, "files": files, "versions": versions,
                                    "reviewRequired": kind in {"align", "reference", "separate", "analyze"}, "modelRevision": request.get("modelRevision")})


if __name__ == "__main__":
    try: main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
