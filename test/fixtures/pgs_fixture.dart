import 'dart:convert';
import 'dart:typed_data';

// Authored synthetic 4x2 PGS canvas: two half-alpha white pixels at (1,1),
// visible from 1s until a clear display set at 2s. No movie subtitle content.
Uint8List syntheticPgsFixture() => base64Decode(
  'UEcAAV+QAAAAABYAEwAEAAIQAACAAAABAAEAAAABAAFQRwABX5AAAAAAFAAHAAAB64CAgFBHAAFfkAAAAAAVAA8AAQDAAAAIAAIAAQEBAABQRwABX5AAAAAAgAAAUEcAAr8gAAAAABYACwAEAAIQAAEAAAAAUEcAAr8gAAAAAIAAAA==',
);
