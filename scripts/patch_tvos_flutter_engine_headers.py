#!/usr/bin/env python3
"""Apply tvOS SDK availability fixes to Plezy's pinned Flutter engine headers.

The custom tvOS engine is distributed as a checksum-pinned framework archive.
Its iOS-compatible public headers guard legacy application callbacks with
TARGET_OS_TV but do not import TargetConditionals explicitly. It also leaves
UIApplicationShortcutItem declarations visible with only API_UNAVAILABLE(tvos).
Xcode 27's tvOS SDK rejects those parameter types while building the Flutter
Clang module. This header-only compatibility shim makes the target guards
effective and hides those iOS-only declarations from tvOS clients.
"""

from __future__ import annotations

import argparse
from pathlib import Path


TARGET_CONDITIONALS = "#import <TargetConditionals.h>"
TVOS_GUARD = "#if !(defined(TARGET_OS_TV) && TARGET_OS_TV)"
SCENE_SHORTCUT_DECLARATIONS = (
    "- (BOOL)windowScene:(UIWindowScene*)windowScene\n"
    "    performActionForShortcutItem:(UIApplicationShortcutItem*)shortcutItem\n"
    "               completionHandler:(void (^)(BOOL succeeded))completionHandler\n"
    "    API_UNAVAILABLE(tvos);",
    "- (void)windowScene:(UIWindowScene*)windowScene\n"
    "    performActionForShortcutItem:(UIApplicationShortcutItem*)shortcutItem\n"
    "               completionHandler:(void (^)(BOOL succeeded))completionHandler\n"
    "    API_UNAVAILABLE(tvos);",
)


def _import_target_conditionals(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if TARGET_CONDITIONALS in text:
        return False

    import_index = text.find("#import ")
    if import_index < 0:
        raise ValueError(f"No import found in {path}")
    text = text[:import_index] + TARGET_CONDITIONALS + "\n" + text[import_index:]
    path.write_text(text, encoding="utf-8")
    return True


def _guard_scene_shortcuts(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False
    for declaration in SCENE_SHORTCUT_DECLARATIONS:
        guarded = f"{TVOS_GUARD}\n{declaration}\n#endif"
        if guarded in text:
            continue
        if text.count(declaration) != 1:
            raise ValueError(
                f"Expected one unguarded tvOS-unavailable shortcut declaration in {path}"
            )
        text = text.replace(declaration, guarded, 1)
        changed = True

    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def patch_engine(engine_dir: Path) -> int:
    frameworks = sorted(engine_dir.glob("out/tvos*/Flutter.framework"))
    if not frameworks:
        raise ValueError(f"No tvOS Flutter.framework outputs found under {engine_dir}")

    patched = 0
    for framework in frameworks:
        headers = framework / "Headers"
        required = (
            headers / "FlutterPlugin.h",
            headers / "FlutterPluginAppLifeCycleDelegate.h",
            headers / "FlutterSceneLifeCycle.h",
        )
        missing = [path.name for path in required if not path.is_file()]
        if missing:
            raise ValueError(f"Missing required Flutter headers in {headers}: {', '.join(missing)}")

        changed = False
        for path in required:
            changed |= _import_target_conditionals(path)
        changed |= _guard_scene_shortcuts(headers / "FlutterSceneLifeCycle.h")
        patched += int(changed)
        print(f"[tvos-engine-headers] checked {headers}; changed={changed}")

    return patched


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine_dir", type=Path, help="Verified tvOS Flutter engine directory")
    args = parser.parse_args()
    engine_dir = args.engine_dir.resolve()
    try:
        patch_engine(engine_dir)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
