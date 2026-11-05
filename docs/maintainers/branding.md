# Pleazyng identity

Pleazyng (pronounced “pleasing”) is published and maintained by SnapeTech.
Use the whole word, with only the initial P capitalized. The symbol is the
fork's coral folded ribbon without NG lettering. Upstream attribution remains
in the project credits and GPL notices.

The canonical master is `assets/branding/source/pleazyng-symbol-master.png`.
Its image-generation provenance is recorded alongside it. Derived mark masters
suppress alpha residue at 16/255 or below. Wordmarks are typeset in DejaVu Sans
Bold Oblique, with navy #071527 on light surfaces and ivory #FFF4E8 on dark.
The font licence is retained in assets/licenses. No upstream logo was supplied
as input to the new symbol. This records provenance, not trademark clearance.

`assets/branding/brand.json` pins every source and export. Use
`AppBrandMark` and `AppBrandWordmark` for in-app surfaces. Keep at least 12%
clear space, a minimum 24-pixel symbol and a 120-pixel wordmark. Do not add
suffix lettering, stretch the artwork or use ivory text on pale backgrounds.
The same symbol works on both surfaces; wordmarks switch for contrast.

All 23 alternate launcher preference IDs remain stable. The exporter covers
Android adaptive/monochrome/notification/TV assets, Apple Icon Composer,
iOS alternates, tvOS layered stacks and shelf formats, Windows ICO/MSIX,
Linux, webOS and web/social exports. Tizen copies assets/pleazyng.png.
SVG wrappers contain raster artwork; they are not vector originals.

```sh
python3 scripts/codegen/generate_brand_assets.py
python3 scripts/codegen/generate_brand_assets.py --check
python3 scripts/checks/check_rebrand.py
python3 -m unittest discover -s scripts/codegen/tests -p 'test_brand_assets.py'
flutter test test/widgets/app_brand_test.dart
```

The inherited README showcase and old-name store screenshot bases have been
removed. Store screenshot slots need fresh captures of the actual branded
build; brand artwork and labelled interface concepts are not store captures.
Third-party provider/player/rating marks and transparent launch placeholders
remain subject to their existing licences and purposes.

The website imports verified bytes using its scripts/sync_branding.py, then
runs npm run build and npm run check. Its repository and currently controlled
domain remain unchanged until explicit cutover. Native compilation, installed
launcher review, signing and actual-device checks remain separate from these
source/export checks. See pleazyng-rebrand-status.json and
pleazyng-rebrand-handoff.md for the remaining gates.
