import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv_path_list.dart';

void main() {
  test('escapes only the Unix path-list separator', () {
    expect(
      MpvPathList.encode(['/opt/shaders/first:variant.glsl', '/opt/shaders/second.glsl'], separator: ':'),
      '/opt/shaders/first\\:variant.glsl:/opt/shaders/second.glsl',
    );
  });

  test('preserves Windows path separators while escaping a semicolon in a path', () {
    expect(
      MpvPathList.encode([r'C:\Program Files\app;preview\shader.glsl', r'D:\shader.glsl'], separator: ';'),
      r'C:\Program Files\app\;preview\shader.glsl;D:\shader.glsl',
    );
  });

  test('rejects an empty path-list separator', () {
    expect(() => MpvPathList.encode(['shader.glsl'], separator: ''), throwsArgumentError);
  });
}
