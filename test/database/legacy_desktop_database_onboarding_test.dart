import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/legacy_desktop_database_onboarding.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/file_picker_service.dart';
import 'package:plezy/utils/platform_detector.dart';

final class _SelectedFilePicker implements FilePickerDelegate {
  _SelectedFilePicker(this.path);

  final String path;
  int pickCount = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool allowMultiple = false,
    bool withData = false,
  }) async {
    pickCount++;
    return FilePickerResult([PlatformFile(name: 'renamed.sqlite', path: path, size: 256)]);
  }

  @override
  Future<String?> getDirectoryPath({String? dialogTitle}) async => null;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    Uint8List? bytes,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
  }) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chooses, previews, and separately confirms a selected database', (tester) async {
    final selected = File('renamed.sqlite').absolute;
    final picker = _SelectedFilePicker(selected.path);
    PlatformDetector.debugSetIsDesktopOSOverride(true);
    FilePickerService.setDelegateForTesting(picker);
    addTearDown(() async {
      PlatformDetector.debugSetIsDesktopOSOverride(null);
      FilePickerService.setDelegateForTesting(null);
    });

    File? importedSource;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                importedSource = await showLegacyDesktopDatabaseOnboarding(
                  context,
                  inspectDatabase: (source) async => LegacyDesktopDatabasePreview(
                    fileName: source.uri.pathSegments.last,
                    fileSizeBytes: 256,
                    schemaVersion: AppDatabase.currentSchemaVersion,
                    downloadedMediaCount: 3,
                    profileCount: 2,
                    connectionCount: 1,
                  ),
                );
              },
              child: const Text('Start'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text(t.startup.legacyImportBody), findsOneWidget);

    await tester.tap(find.text(t.startup.legacyImportChoose));
    await tester.pumpAndSettle();
    expect(picker.pickCount, 1);
    expect(find.text(t.startup.legacyImportReviewTitle), findsOneWidget);
    expect(find.text(t.startup.legacyImportFile(name: 'renamed.sqlite')), findsOneWidget);
    expect(find.text(t.startup.legacyImportProfiles(count: 2)), findsOneWidget);
    expect(find.text(t.startup.legacyImportCredentialsWarning), findsOneWidget);
    expect(find.text(t.startup.legacyImportPathsWarning), findsOneWidget);
    expect(importedSource, isNull, reason: 'selecting a file must not import before the separate confirmation');

    await tester.tap(find.text(t.startup.legacyImportConfirm));
    await tester.pumpAndSettle();

    expect(importedSource?.path, selected.path);
  });

  testWidgets('does not offer migration off desktop', (tester) async {
    final picker = _SelectedFilePicker(File('legacy.sqlite').absolute.path);
    PlatformDetector.debugSetIsDesktopOSOverride(false);
    FilePickerService.setDelegateForTesting(picker);
    addTearDown(() async {
      PlatformDetector.debugSetIsDesktopOSOverride(null);
      FilePickerService.setDelegateForTesting(null);
    });

    File? importedSource;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                importedSource = await showLegacyDesktopDatabaseOnboarding(context);
              },
              child: const Text('Start'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    expect(find.text(t.startup.legacyImportTitle), findsNothing);
    expect(picker.pickCount, 0);
    expect(importedSource, isNull);
  });
}
