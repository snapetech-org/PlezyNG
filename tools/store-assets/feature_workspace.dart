// Uses the real workspace chrome and placement controller.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:plezy/multiview/workspace_controller.dart';
import 'package:plezy/multiview/workspace_models.dart';
import 'package:plezy/multiview/workspace_overlay.dart';
import 'package:plezy/screens/sources/sources_screen.dart';
import 'player_mockup.dart';

class FeatureWorkspace extends StatefulWidget {
  const FeatureWorkspace({super.key, required this.controller, required this.readerImage});
  final MultiviewWorkspaceController controller;
  final String readerImage;
  @override
  State<FeatureWorkspace> createState() => _FeatureWorkspaceState();
}

class _FeatureWorkspaceState extends State<FeatureWorkspace> {
  final overlay = GlobalKey<OverlayState>();
  @override
  void initState() {
    super.initState();
    widget.controller.register(
      WorkspaceSurfaceRegistration(
        descriptor: WorkspaceSessionDescriptor(
          id: 'gallery-reader',
          kind: MultiviewMediaKind.publication,
          title: 'The Night Library',
          openedAt: DateTime(2026, 11, 5),
        ),
        buildSurface: (_) => ColoredBox(
          color: const Color(0xFF131313),
          child: Image.memory(File(widget.readerImage).readAsBytesSync(), fit: BoxFit.contain),
        ),
        onRestore: () {},
        onClose: () {},
      ),
    );
    widget.controller.register(
      WorkspaceSurfaceRegistration(
        descriptor: WorkspaceSessionDescriptor(
          id: 'gallery-video',
          kind: MultiviewMediaKind.video,
          title: 'Caminandes: Gran Dillama',
          hasVideo: true,
          openedAt: DateTime(2026, 11, 5),
        ),
        buildSurface: (_) => const PlayerMockup(),
        onRestore: () {},
        onClose: () {},
      ),
    );
    widget.controller.resizeByPixels('gallery-reader', const Offset(150, 250), const Size(1280, 900));
    widget.controller.moveToCorner('gallery-reader', right: false, bottom: false);
    widget.controller.moveByPixels('gallery-reader', const Offset(20, 70), const Size(1280, 900));
    widget.controller.resizeByPixels('gallery-video', const Offset(60, 100), const Size(1280, 900));
    widget.controller.moveToCorner('gallery-video', right: true, bottom: true);
    widget.controller.moveByPixels('gallery-video', const Offset(-20, -65), const Size(1280, 900));
  }

  @override
  Widget build(BuildContext context) => Overlay(
    key: overlay,
    initialEntries: [
      OverlayEntry(
        builder: (_) => Stack(
          fit: StackFit.expand,
          children: [
            const SourcesScreen(),
            MultiviewOverlayHost(controller: widget.controller, overlayKey: overlay),
          ],
        ),
      ),
    ],
  );
}
