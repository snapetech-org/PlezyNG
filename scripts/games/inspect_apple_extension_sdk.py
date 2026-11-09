#!/usr/bin/env python3
"""Capture the selected SDK's public extension contracts for compile validation."""
from pathlib import Path
import subprocess
import urllib.request

output = Path('build/romm-extension-sdk')
output.mkdir(parents=True, exist_ok=True)
for sdk in ('iphoneos', 'appletvos'):
    root = Path(subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip())
    for framework in ('ExtensionFoundation', 'ExtensionKit', 'XPC'):
        directory = root / 'System/Library/Frameworks' / (framework + '.framework')
        for source in directory.glob('Modules/**/*.swiftinterface'):
            if source.name.endswith('.private.swiftinterface'):
                continue
            (output / (sdk + '-' + framework + '-' + source.name)).write_bytes(source.read_bytes())
    for source in (root / 'usr/lib/swift/XPC.swiftmodule').glob('*.swiftinterface'):
        if not source.name.endswith('.private.swiftinterface'):
            (output / (sdk + '-XPC-' + source.name)).write_bytes(source.read_bytes())
            # Public SDK contracts only; available in logs when a workspace
            # cannot retrieve the binary artifact.
            print('PUBLIC XPC CONTRACT: ' + source.name)
            print(source.read_text()[:80000])
developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
template_roots = [developer / 'Library/Xcode/Templates']
template_roots += list((developer / 'Platforms').glob('*.platform/Developer/Library/Xcode/Templates'))
for base in template_roots:
    for template in base.rglob('TemplateInfo.plist'):
        text = template.read_text(errors='replace')
        if 'Enhanced Security' in text or 'enhanced-security' in text:
            print('PUBLIC XCODE TEMPLATE: ' + str(template.relative_to(developer)))
            print(text[:30000])
            for filename in ('AppExtension-EnhancedSecurity.swift', 'AppExtension-EnhancedSecurity.entitlements'):
                source = template.parent / filename
                if source.is_file():
                    print('PUBLIC XCODE SOURCE: ' + filename)
                    print(source.read_text()[:30000])
for name, url in {
    'enhanced-security.md': 'https://developer.apple.com/documentation/xcode/creating-enhanced-security-helper-extensions.md',
    'extension-host.md': 'https://developer.apple.com/documentation/extensionfoundation/adding-support-for-app-extensions-to-your-app.md',
    'extension-implementation.md': 'https://developer.apple.com/documentation/extensionfoundation/building-an-app-extension-to-support-a-host-app.md',
}.items():
    with urllib.request.urlopen(url, timeout=30) as response:
        (output / name).write_bytes(response.read(1024 * 1024))
print('Captured public SDK interfaces and Apple extension implementation guidance')
