# Native theme packages

Theme packages v1 are UTF-8 JSON files, at most 128 KiB. Open Appearance → Theme
→ Custom → Import Settings, import a package, inspect the preview, then Save.
The same screen exports a package and resets the installed package. Custom
themes use the existing entitlement policy. Invalid packages leave the installed
theme unchanged; corrupt stored packages fall back through the normal theme
selection. Existing palette-only custom themes need no migration.

Required fields are `schemaVersion: 1`, a stable lowercase `id` (letters, digits,
period, underscore, hyphen; at most 64 characters), a `name` (at most 80
characters), and `palette`. The palette uses the existing six named color slots:
`bg`, `surface`, `outline`, `text`, `textMuted`, `accent`; each is `#RRGGBB` or
`#AARRGGBB`.

Optional semantic styles:

| Section | Keys | Bounds/defaults |
| --- | --- | --- |
| `geometry` | `radiusSm`, `radiusMd`, `radiusLg`, `radiusXs` | 0–40, 0–40, 0–48, 0–24; defaults 8, 12, 20, 5 |
| `geometry` | `space`, `groupGap` | 8–24 and 0–12; defaults 12 and 2 |
| `typography` | `scale` | 0.9–1.3; default 1; OS text scaling still applies |
| `layout` | `navigation` | `adaptive`, `sidebar`, `bottom`; default `adaptive` |

Geometry updates shared native tokens, card/dialog shapes and list padding.
Primary and secondary buttons and navigation selection shapes follow `radiusMd`;
poster corners follow `radiusSm`, and overlay sheets follow `radiusLg`.
Selection markers follow the leading edge in RTL.
Typography updates the text theme. Navigation changes the application shell:
sidebar is used when the viewport has at least 840 logical pixels; bottom uses
the bottom bar. TV and automotive keep their existing focus/navigation contracts.
Directional padding and positioning follow the active RTL locale.

`examples/cinema.plezy-theme.json` and `examples/paper.plezy-theme.json` demonstrate
different colors, shapes, spacing, typography and navigation flow. Use either as
the starting point for a submission. Include screenshots at normal and 200% OS
text, an RTL locale, keyboard/D-pad navigation, light/dark content and the package
file. Keep text, controls and focus rings legible. Editing a palette through the
older color editor resets package geometry to the built-in geometry.

Native packages accept declarative JSON styles. They do not execute scripts or
load remote fonts, images, CSS or widget code. Reader HTML/CSS belongs to the
reader's stylesheet settings; web CSS does not restyle Flutter widgets. New
tokens or layout variants require a schema revision with a native implementation
and migration. Unknown fields and unsupported versions are rejected.

Schema and round-trip regression cases are provided. Device, TV focus, RTL and
200% OS-text execution remain pending. The examples are original sample styles;
they are not a claim of pixel-exact reproduction of reference mockups.
