import '../i18n/strings.g.dart';
import 'extras_models.dart';

String extraKindLabel(ExtraKind kind) => switch (kind) {
  ExtraKind.makingOf => t.bonusExtras.kind.makingOf,
  ExtraKind.effects => t.bonusExtras.kind.effects,
  ExtraKind.makeup => t.bonusExtras.kind.makeup,
  ExtraKind.interview => t.bonusExtras.kind.interview,
  ExtraKind.deletedScene => t.bonusExtras.kind.deletedScene,
  ExtraKind.bloopers => t.bonusExtras.kind.bloopers,
  ExtraKind.commentary => t.bonusExtras.kind.commentary,
  ExtraKind.trailer => t.bonusExtras.kind.trailer,
  ExtraKind.analysis => t.bonusExtras.kind.analysis,
  ExtraKind.other => t.bonusExtras.kind.other,
};
String extrasAiLabel(ExtrasAiMode mode) => switch (mode) {
  ExtrasAiMode.off => t.bonusExtras.aiOff,
  ExtrasAiMode.device => t.bonusExtras.aiDevice,
  ExtrasAiMode.server => t.bonusExtras.aiServer,
  ExtrasAiMode.cloud => t.bonusExtras.aiCloud,
};
String extraSourceLabel(ExtraEntry entry) => entry.isLibrary
    ? t.bonusExtras.library
    : entry.origin == ExtraOrigin.user
    ? t.bonusExtras.personal
    : entry.publisher.isEmpty
    ? t.bonusExtras.external
    : entry.publisher;
