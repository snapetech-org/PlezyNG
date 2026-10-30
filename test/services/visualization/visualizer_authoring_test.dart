import 'dart:convert';

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
}
