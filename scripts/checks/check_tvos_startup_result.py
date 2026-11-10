#!/usr/bin/env python3
"""Require a passing real Dart database startup test in an Xcode result."""
import json
from pathlib import Path
import sys

IDENTIFIER = 'FlutterNativeTextInputTests/testPackagedNativeAssetsOpenTheRealDartDatabase'


def validate(value):
    results = []

    def visit(node):
        if isinstance(node, dict):
            if node.get('nodeType') == 'Test Case' and node.get('nodeIdentifier', '').removesuffix('()') == IDENTIFIER:
                results.append(node.get('result'))
            for child in node.values():
                visit(child)
        elif isinstance(node, list):
            for child in node:
                visit(child)

    visit(value)
    if not results or any(result != 'Passed' for result in results):
        raise ValueError(f'Real Dart database startup was not qualified: {results or "test missing"}')


if __name__ == '__main__':
    validate(json.loads(Path(sys.argv[1]).read_text()))
    print('Real tvOS Dart database open and pinned SQLite version qualified by native XCTest.')
