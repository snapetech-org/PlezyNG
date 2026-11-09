import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../media/media_kind.dart';
import '../models/seerr/seerr_request_intent.dart';
import '../models/seerr/seerr_request.dart';
import '../models/seerr/seerr_details.dart';
import '../services/catalog/seerr_catalog_source.dart';
import '../services/seerr/seerr_exceptions.dart';
import '../utils/app_logger.dart';
import '../utils/snackbar_helper.dart';
import 'seerr_request_sheet.dart';

enum SeerrTitleActionKind {
  request,
  requestSeasons,
  request4k,
  notify,
  notify4k,
  notificationsOn,
  requested,
  available,
}

final Set<String> _quickRequestsInFlight = {};

class SeerrTitleAction {
  final SeerrTitleActionKind kind;
  const SeerrTitleAction(this.kind);

  String get label => switch (kind) {
    SeerrTitleActionKind.request => t.seerr.request,
    SeerrTitleActionKind.requestSeasons => t.seerr.requestSeasons,
    SeerrTitleActionKind.request4k => t.seerr.request4k,
    SeerrTitleActionKind.notify => t.seerr.notifyMe,
    SeerrTitleActionKind.notify4k => t.seerr.notifyMe4k,
    SeerrTitleActionKind.notificationsOn => t.seerr.notificationsOn,
    SeerrTitleActionKind.requested => t.seerr.statusRequested,
    SeerrTitleActionKind.available => t.seerr.statusAvailable,
  };

  IconData get icon => switch (kind) {
    SeerrTitleActionKind.request || SeerrTitleActionKind.requestSeasons => Symbols.add_rounded,
    SeerrTitleActionKind.request4k => Symbols.four_k_rounded,
    SeerrTitleActionKind.notify || SeerrTitleActionKind.notify4k => Symbols.notification_add_rounded,
    SeerrTitleActionKind.notificationsOn => Symbols.notifications_active_rounded,
    SeerrTitleActionKind.requested => Symbols.schedule_rounded,
    SeerrTitleActionKind.available => Symbols.check_circle_rounded,
  };

  bool get interactive => kind != SeerrTitleActionKind.requested && kind != SeerrTitleActionKind.available;
}

/// The next action for this viewer. SeerrNG's projection is authoritative for
/// the viewer; older instances still get the existing request sheet, which
/// checks availability again before accepting a request.
SeerrTitleAction? seerrTitleAction(
  SeerrCatalogSource source,
  MediaKind kind,
  SeerrRequestIntent? state, {
  int? seasonNumber,
}) {
  if (!source.canRequest(kind)) return null;
  if (state == null) return const SeerrTitleAction(SeerrTitleActionKind.request);
  final season = seasonNumber == null ? null : state.seasons.where((entry) => entry.number == seasonNumber).firstOrNull;
  if (season != null) {
    if (state.subscribed && state.subscriptionSeasonNumber == seasonNumber) {
      return const SeerrTitleAction(SeerrTitleActionKind.notificationsOn);
    }
    if (season.status == 5) return const SeerrTitleAction(SeerrTitleActionKind.available);
    if (season.standardOwn != null) return const SeerrTitleAction(SeerrTitleActionKind.requested);
    if (season.standardOther != null && season.canSubscribe) return const SeerrTitleAction(SeerrTitleActionKind.notify);
    if (state.canRequest) return const SeerrTitleAction(SeerrTitleActionKind.requestSeasons);
  }
  if (seasonNumber != null && state.canRequest) return const SeerrTitleAction(SeerrTitleActionKind.requestSeasons);
  if (kind == MediaKind.show && state.canRequest && state.hasMissingSeasons) {
    return const SeerrTitleAction(SeerrTitleActionKind.requestSeasons);
  }
  if (state.subscribed && state.subscriptionSeasonNumber == null) {
    if (state.subscriptionIs4k == true &&
        !state.available &&
        state.canRequest &&
        state.own == null &&
        state.other == null) {
      return const SeerrTitleAction(SeerrTitleActionKind.request);
    }
    return const SeerrTitleAction(SeerrTitleActionKind.notificationsOn);
  }
  if (state.available) {
    if (state.other4k != null && state.canSubscribe4k) return const SeerrTitleAction(SeerrTitleActionKind.notify4k);
    if (state.canRequest4k && state.status4k != 5 && state.own4k == null && state.other4k == null) {
      return const SeerrTitleAction(SeerrTitleActionKind.request4k);
    }
    return const SeerrTitleAction(SeerrTitleActionKind.available);
  }
  if (state.hasOwnRequest) return const SeerrTitleAction(SeerrTitleActionKind.requested);
  if (state.hasOtherRequest) {
    return SeerrTitleAction(
      state.other != null && state.canSubscribe
          ? SeerrTitleActionKind.notify
          : state.other4k != null && state.canSubscribe4k
          ? SeerrTitleActionKind.notify4k
          : SeerrTitleActionKind.requested,
    );
  }
  if (!state.canRequest || state.status == 6) return null;
  return const SeerrTitleAction(SeerrTitleActionKind.request);
}

/// Library titles already have Play; only missing seasons and an independent
/// 4K variant are useful there. The server state is required before showing
/// either option, so an unresolved identity never becomes a false request.
bool hasNewSeerrSeason(SeerrRequestIntent state, SeerrDetails details, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final known = state.seasons.map((season) => season.number).toSet();
  return (details.seasons ?? const <SeerrSeason>[]).any((season) {
    if (season.seasonNumber < 1 || (season.episodeCount ?? 0) < 1 || known.contains(season.seasonNumber)) return false;
    final aired = DateTime.tryParse(season.airDate ?? '');
    return aired != null && !aired.isAfter(today);
  });
}

SeerrTitleAction? librarySeerrTitleAction(
  SeerrCatalogSource source,
  MediaKind kind,
  SeerrRequestIntent? state, {
  bool hasNewSeason = false,
}) {
  if (state == null || !source.canRequest(kind)) return null;
  if (kind == MediaKind.show && state.canRequest && (state.hasMissingSeasons || hasNewSeason || state.status == 4)) {
    return const SeerrTitleAction(SeerrTitleActionKind.requestSeasons);
  }
  if (state.other4k != null && state.canSubscribe4k) {
    return SeerrTitleAction(
      state.subscribed && state.subscriptionIs4k == true
          ? SeerrTitleActionKind.notificationsOn
          : SeerrTitleActionKind.notify4k,
    );
  }
  if (state.canRequest4k && state.status4k != 5 && state.own4k == null && state.other4k == null) {
    return const SeerrTitleAction(SeerrTitleActionKind.request4k);
  }
  return null;
}

Future<void> performSeerrTitleAction(
  BuildContext context, {
  required SeerrCatalogSource source,
  required MediaKind kind,
  required int tmdbId,
  required String title,
  required SeerrTitleAction action,
  int? seasonNumber,
}) async {
  if (!action.interactive) return;
  if (action.kind == SeerrTitleActionKind.notify ||
      action.kind == SeerrTitleActionKind.notify4k ||
      action.kind == SeerrTitleActionKind.notificationsOn) {
    try {
      if (action.kind == SeerrTitleActionKind.notify || action.kind == SeerrTitleActionKind.notify4k) {
        await source.client.subscribeToAvailability(
          kind,
          tmdbId,
          is4k: action.kind == SeerrTitleActionKind.notify4k,
          seasonNumber: seasonNumber,
        );
      } else {
        await source.client.unsubscribeFromAvailability(kind, tmdbId);
      }
      if (!context.mounted) return;
      unawaited(source.client.intents.load(kind, tmdbId));
      showSuccessSnackBar(
        context,
        action.kind != SeerrTitleActionKind.notificationsOn
            ? t.seerr.notificationsEnabled
            : t.seerr.notificationsDisabled,
      );
    } on SeerrApiException catch (e) {
      if (context.mounted) showErrorSnackBar(context, e.message);
    } catch (e) {
      appLogger.w('Seerr: availability subscription failed', error: e);
      if (context.mounted) showErrorSnackBar(context, t.seerr.notificationFailed);
    }
    return;
  }
  final intent = source.client.intents.peek(kind, tmdbId);
  if (kind == MediaKind.movie && action.kind == SeerrTitleActionKind.request && intent?.quickRequest == true) {
    final key = '${identityHashCode(source.client)}:movie:$tmdbId';
    if (!_quickRequestsInFlight.add(key)) return;
    try {
      await source.client.createRequest(SeerrRequestPayload(mediaType: 'movie', mediaId: tmdbId));
      if (context.mounted) {
        unawaited(source.client.intents.load(kind, tmdbId));
        showSuccessSnackBar(context, t.seerr.requestSubmitted);
      }
    } on SeerrApiException catch (e) {
      if (context.mounted) showErrorSnackBar(context, e.message);
      unawaited(source.client.intents.refresh(kind, tmdbId));
    } catch (e) {
      appLogger.w('Seerr: quick request failed', error: e);
      if (context.mounted) showErrorSnackBar(context, t.seerr.requestFailed(error: '$e'));
    } finally {
      _quickRequestsInFlight.remove(key);
    }
    return;
  }
  await showSeerrRequestSheet(
    context,
    source: source,
    kind: kind,
    tmdbId: tmdbId,
    title: title,
    seasonNumber: seasonNumber,
    prefer4k: action.kind == SeerrTitleActionKind.request4k,
  );
}
