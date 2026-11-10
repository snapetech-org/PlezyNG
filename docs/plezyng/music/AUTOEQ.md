# Headphone EQ catalog

Music → Audio → AutoEq searches 6,029 bundled headphone profiles without a
network request. Selecting a profile previews its response in the existing
ten-band editor. Save applies it to the current music session; Save as preset
keeps a named profile. The output-EQ section assigns the displayed bands/preamp
to the selected engine output, reapplies them when that output is selected, and
restores general EQ when another output is used. Reset removes the assignment.
Assignments belong to the active Pleazyng profile. Outputs are enumerated from
the active player; engine output `auto` is one route identifier, not a promise
to distinguish every Bluetooth/headphone device hidden behind an OS mixer.

The bundled curves are **ten-band approximations**, with gains clamped to the
editor's ±12 dB range. They do not reproduce the full dense response or establish
measured correction on the physical headphones. Existing music EQ headroom
attenuation also applies. The picker explicitly describes the approximation.

## Data and license

AutoEq data is by Jaakko Pasanen and the AutoEq contributors, under the MIT
license. This is an independent integration of that data, not an endorsement.
The original license is bundled as `assets/licenses/AutoEq_MIT.txt` and shown in
Pleazyng's Licenses screen.

- Project: <https://github.com/jaakkopasanen/AutoEq>
- Pinned revision: `7ae0f56d53074872b028649617a22bbb4232feb7`
- Source: <https://raw.githubusercontent.com/jaakkopasanen/AutoEq/7ae0f56d53074872b028649617a22bbb4232feb7/results/hesuvi.zip>
- SHA-256: `96cc6df6cad65523c120cfd263f2c42a32eeb8a14a82dbfda25f23699c50c00b`

The source archive supplies 6,033 entries, including four repeated paths with
different curves. The generator keeps the last occurrence, matching normal ZIP
extraction, to produce 6,029 unique selectable profiles. Model names and
source archive entry paths are retained in `assets/music/autoeq.json`.
The deterministic generator resamples gain linearly in logarithmic frequency
at 31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000 and 16000 Hz. Values are
rounded to 0.001 dB after clamping. No measurements or model names are invented.

Reproduce or verify the asset with a local copy of the pinned archive:

```sh
python3 scripts/codegen/generate_music_autoeq.py /path/to/hesuvi.zip
python3 scripts/codegen/generate_music_autoeq.py /path/to/hesuvi.zip --check
```

The generator verifies the source digest before reading the ZIP and does not
extract archive paths to disk. Updating the pin requires rechecking the source
license, rebuilding the asset, running the catalog/search/UI tests and reviewing
the resulting profile count and source attribution.
