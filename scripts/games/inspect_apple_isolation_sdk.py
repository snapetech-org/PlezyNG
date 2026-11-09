#!/usr/bin/env python3
"""Report public SDK extension APIs needed to qualify mobile worker packaging."""
from pathlib import Path
import re
import subprocess

KEYWORDS = re.compile(r'AppExtensionProcess|ConnectionHandler|AppExtensionPoint|XPCPeerHandler|AppExtensionConfiguration|EnhancedSecurity|extensionkit-extension|hardened-process|ExtensionFoundation')

for sdk in ('iphonesimulator', 'appletvsimulator', 'macosx'):
    root = Path(subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip())
    modules = sorted((root / 'System/Library/Frameworks/ExtensionFoundation.framework/Modules/ExtensionFoundation.swiftmodule').glob('*.swiftinterface'))
    print(f'PUBLIC SDK: {sdk}')
    if not modules:
        print('ExtensionFoundation public Swift interface unavailable')
        continue
    lines = modules[0].read_text().splitlines()
    selected = set()
    for n, line in enumerate(lines):
        if KEYWORDS.search(line):
            selected.update(range(max(0, n - 4), min(len(lines), n + 16)))
    for n in sorted(selected):
        print(f'{n + 1}: {lines[n]}')

developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
for templates in (developer / 'Library/Xcode/Templates', developer / 'Platforms/iPhoneOS.platform/Developer/Library/Xcode/Templates'):
    for file in sorted(templates.rglob('TemplateInfo.plist')):
        if 'Extension' not in str(file) or file.stat().st_size > 256000:
            continue
        lines = file.read_text().splitlines()
        selected = set()
        for n, line in enumerate(lines):
            if KEYWORDS.search(line):
                selected.update(range(max(0, n - 5), min(len(lines), n + 12)))
        if selected:
            print(f'PUBLIC TEMPLATE: {file.relative_to(developer)}')
            for n in sorted(selected):
                print(f'{n + 1}: {lines[n]}')
