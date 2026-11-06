import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:plezy/i18n/strings.g.dart';

/// Samsung's rootstrap has no compatible PDFium runtime.
class RommManualView extends StatelessWidget {
  const RommManualView({super.key, required this.bytes, required this.sourceName});

  static const supported = false;
  final Uint8List bytes;
  final String sourceName;

  @override
  Widget build(BuildContext context) => Center(child: Text(t.fileSources.errorUnsupported));
}
