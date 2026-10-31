#!/usr/bin/env python3
"""Hide iOS-only callback declarations from Plezy's pinned tvOS engine.

The checksum-pinned Flutter engine reuses iOS public headers for tvOS. Several
UIApplication callback declarations expose types that the tvOS SDK no longer
defines, and Flutter does not guard them for tvOS. Xcode 27 rejects these
declarations while building the Flutter Clang module. Add explicit target
guards to those declarations and import TargetConditionals in each header.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


TARGET_CONDITIONALS = "#import <TargetConditionals.h>"
TVOS_GUARD = "#if !(defined(TARGET_OS_TV) && TARGET_OS_TV)"
IOS_ONLY_METHODS = {
    "FlutterPlugin.h": (
        ("UIUserNotificationSettings*", 1),
        ("UILocalNotification*", 1),
        ("UIApplicationShortcutItem*", 1),
    ),
    "FlutterPluginAppLifeCycleDelegate.h": (
        ("UIUserNotificationSettings*", 1),
        ("UILocalNotification*", 1),
        ("UIApplicationShortcutItem*", 1),
    ),
    "FlutterSceneLifeCycle.h": (("UIApplicationShortcutItem*", 2),),
}


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


def _open_preprocessor_guards(text: str, before: int) -> list[str]:
    stack: list[str] = []
    for line in text[:before].splitlines():
        directive = line.strip()
        if re.match(r"#\s*(if|ifdef|ifndef)\b", directive):
            stack.append(directive)
        elif re.match(r"#\s*endif\b", directive) and stack:
            stack.pop()
    return stack


def _guard_methods(path: Path, markers: tuple[tuple[str, int], ...]) -> bool:
    text = path.read_text(encoding="utf-8")
    starts = [match.start() for match in re.finditer(r"(?m)^-[ \t]+\(", text)]
    declarations: list[tuple[int, int, str]] = []
    for start in starts:
        end = text.find(";", start)
        if end < 0:
            raise ValueError(f"Unterminated Objective-C method declaration in {path}")
        declarations.append((start, end + 1, text[start : end + 1]))

    to_guard: set[tuple[int, int]] = set()
    for marker, expected_count in markers:
        matches = [
            (start, end)
            for start, end, declaration in declarations
            if marker in declaration
        ]
        if len(matches) != expected_count:
            raise ValueError(
                f"Expected {expected_count} Objective-C declarations containing "
                f"{marker!r} in {path}, found {len(matches)}"
            )
        for start, end in matches:
            if TVOS_GUARD not in _open_preprocessor_guards(text, start):
                to_guard.add((start, end))

    for start, end in sorted(to_guard, reverse=True):
        text = text[:start] + f"{TVOS_GUARD}\n" + text[start:end] + f"\n#endif" + text[end:]

    if to_guard:
        path.write_text(text, encoding="utf-8")
    return bool(to_guard)


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
            changed |= _guard_methods(path, IOS_ONLY_METHODS[path.name])
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
