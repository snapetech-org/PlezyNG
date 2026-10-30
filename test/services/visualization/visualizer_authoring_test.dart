import 'dart:convert';

import 'package:plezy/services/visualization/visualizer_content_limits.dart';
import 'package:plezy/services/visualization/visualizer_pack_store.dart';
import 'package:plezy/services/visualization/visualizer_session.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/visualization/visualizer_fragments.dart';
import 'package:plezy/services/visualization/visualizer_pack_dependencies.dart';
import 'package:plezy/services/visualization/visualizer_catalog_entry.dart';

void main() {
  test('fragment composition preserves occupied slots and all source equations', () {
    final preset = utf8.encode('[preset00]\nname=Original\nshapecode_0_enabled=1\nshape_0_per_frame1=x=x+0.1;\nunknown=value\n');
    final fragment = utf8.encode('[shape]\nenabled=0\nsides=37\ninit_1=t1=2;\nper_frame_1=x=x+t1;\ncustom_field=kept\n');
    final result = VisualizerFragments.compose(preset, fragment, 'shape');
    expect(result, startsWith(utf8.decode(preset)));
    expect(result, contains('shapecode_1_enabled=0'));
    expect(result, contains('shape_1_init_1=t1=2;'));
    expect(result, contains('shape_1_per_frame_1=x=x+t1;'));
    expect(result, contains('shapecode_1_custom_field=kept'));
    final exported = VisualizerFragments.extract(utf8.encode(result), 'shape');
    expect(exported.keys.toSet(), {0, 1});
    expect(exported[1], contains('custom_field=kept'));
    expect(exported[1], contains('per_frame_1=x=x+t1;'));
  });

  test('fragment import rejects mixed types, overflow and remote includes', () {
    final preset = utf8.encode('[preset00]\nname=Fixture\n');
    for (final source in ['shape_0_enabled=1\nwave_1_enabled=1', 'shapecode_64_enabled=1',
        'shape_0_enabled=1\nenabled=1', 'per_frame_1=#include \"remote.fx\"']) {
      expect(() => VisualizerFragments.compose(preset, utf8.encode(source), 'shape'), throwsFormatException);
    }
    expect(() => VisualizerFragments.compose(utf8.encode('[preset00]\nx=0\n[preset01]\nx=1'),
        utf8.encode('enabled=1'), 'shape'), throwsFormatException);
  });

  test('texture dependency identities are immutable, bounded and portable', () {
    final item = {'id': 'textures', 'version': '1.0', 'integritySha256': List.filled(64, 'a').join()};
    expect(VisualizerTextureDependency.parse([item]).single.identity, 'textures@1.0');
    expect(() => VisualizerTextureDependency.parse([item, item]), throwsFormatException);
    for (final id in ['../escape', 'CON', 'textures.previous', 'textures.partial', 'trailing.']) {
      expect(() => VisualizerTextureDependency.parse([{...item, 'id': id}]), throwsFormatException);
    }
    expect(() => VisualizerTextureDependency.parse([{...item, 'integritySha256': 'moving'}]), throwsFormatException);
    expect(() => VisualizerTextureDependency.parse(List.filled(17, item)), throwsFormatException);
  });

  test('zero preset count is exclusive to texture packs', () {
    final sample = VisualizerPackCatalogEntry.available.first.toJson();
    expect(VisualizerPackCatalogEntry.fromJson({...sample, 'kind': 'textures', 'presetCount': 0}).kind, 'textures');
    expect(() => VisualizerPackCatalogEntry.fromJson({...sample, 'presetCount': 0}), throwsFormatException);
    expect(() => VisualizerPackCatalogEntry.fromJson({...sample, 'kind': 'textures'}), throwsFormatException);
  });
  test('composition refuses to invent a fifth active object slot', () {
    final preset = utf8.encode('[preset00]\n${List.generate(4, (i) => 'shapecode_${i}_enabled=0').join('\n')}\n');
    expect(() => VisualizerFragments.compose(preset, utf8.encode('enabled=1'), 'shape'), throwsFormatException);
  });

  test('converted profile survives loose import and engine negotiation', () {
    final source = utf8.encode('// MILKRUST_REQUIRED_PROFILE=butterchurn-numeric-v1\n[preset00]\nper_frame_1=assign(x,bcjsDivide(1,2));\n');
    expect(VisualizerContentLimits.presetRequiresMilkRust(source), isTrue);
    expect(VisualizerContentLimits.presetRequiresMilkRust(utf8.encode('[preset00]\nzoom=1')), isFalse);
    expect(() => VisualizerContentLimits.checkPreset(utf8.encode('// MILKRUST_REQUIRED_PROFILE=future-v99\n[preset00]')), throwsFormatException);
    const converted = VisualizerPresetFile(id: 'converted', title: 'Converted', path: '/presets/a.milk',
        root: '/presets', libraryPath: 'a.milk', requiresMilkRust: true);
    expect(converted.isClassicPreset, isTrue);
    expect(converted.supportsProjectM, isFalse);
    expect(const VisualizerCapabilities(available: true, reason: '', engine: 'milkrust-native').accepts(converted), isTrue);
    expect(const VisualizerCapabilities(available: true, reason: '', engine: 'projectm').accepts(converted), isFalse);
    expect(() => VisualizerContentLimits.checkEngineRequirement({'requiredProfile': 'butterchurn-numeric-v1'}), throwsFormatException);
    expect(() => VisualizerContentLimits.checkEngineRequirement({'requiredEngine': 'unknown'}), throwsFormatException);
  });

}
