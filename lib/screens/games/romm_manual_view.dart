import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

/// The PDF surface is replaced by the TV adapter where PDFium is unsupported.
class RommManualView extends StatelessWidget {
  const RommManualView({super.key, required this.bytes, required this.sourceName});

  static const supported = true;
  final Uint8List bytes;
  final String sourceName;

  @override
  Widget build(BuildContext context) => PdfViewer.data(bytes, sourceName: sourceName);
}
