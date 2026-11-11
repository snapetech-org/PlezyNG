import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../services/music/music_experience.dart';
import '../../services/music/music_home_pins.dart';
import '../../utils/snackbar_helper.dart';

bool canPinMusicHomeItem(BuildContext context, MediaItem item) {
  final experience = context.read<MusicExperience?>();
  final client = experience?.clientFor(item);
  return experience?.store.active == true &&
      MusicHomePin.kinds.contains(item.kind) &&
      client != null &&
      !client.isOfflineMode;
}

Future<void> saveMusicHomePin(BuildContext context, MediaItem item) async {
  final pins = context.read<MusicExperience?>()?.pins;
  if (pins == null) return;
  try {
    await pins.save(item);
    if (context.mounted) showAppSnackBar(context, t.musicExperience.saved);
  } catch (_) {
    if (context.mounted) showErrorSnackBar(context, t.musicExperience.error);
  }
}
