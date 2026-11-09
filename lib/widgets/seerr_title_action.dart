import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../media/media_kind.dart';
import '../models/seerr/seerr_request_intent.dart';
import '../models/seerr/seerr_request.dart';
import '../models/seerr/seerr_details.dart';
import '../models/seerr/seerr_media.dart';
import '../models/seerr/seerr_public_settings.dart';
import '../services/catalog/seerr_catalog_source.dart';
import '../services/seerr/seerr_exceptions.dart';
import '../utils/app_logger.dart';
import '../utils/error_message_utils.dart';
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
    SeerrTitleActionKind.notificationsOn => t.seerr.turnOffAlert,
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

  String tooltip({bool quickRequest = false}) => switch (kind) {
    SeerrTitleActionKind.request => quickRequest ? t.seerr.quickRequestHint : t.seerr.requestHint,
    SeerrTitleActionKind.requestSeasons => t.seerr.chooseSeasonsHint,
    SeerrTitleActionKind.request4k => t.seerr.request4kHint,
    _ => label,
  };
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
  if (!source.supportsTitleActions(kind)) return null;
  if (state == null) {
    if (source.canRequest(kind)) return const SeerrTitleAction(SeerrTitleActionKind.request);
    return source.canRequest4k(kind) ? const SeerrTitleAction(SeerrTitleActionKind.request4k) : null;
  }
  final canRequest = source.canRequest(kind) && state.canRequest;
  final canRequest4k = source.canRequest4k(kind) && state.canRequest4k;
  if (state.status == 6) return null; // SeerrNG has blocklisted the title.
  final season = seasonNumber == null ? null : state.seasons.where((entry) => entry.number == seasonNumber).firstOrNull;
  if (season != null) {
    if (state.subscribed && state.subscriptionSeasonNumber == seasonNumber) {
      return const SeerrTitleAction(SeerrTitleActionKind.notificationsOn);
    }
    if (season.status == 5) return const SeerrTitleAction(SeerrTitleActionKind.available);
    if (season.status == 6) return null;
    if (season.standardOwn != null) return const SeerrTitleAction(SeerrTitleActionKind.requested);
    if (season.standardOther != null && season.canSubscribe) return const SeerrTitleAction(SeerrTitleActionKind.notify);
    if (canRequest) return const SeerrTitleAction(SeerrTitleActionKind.requestSeasons);
  }
  if (seasonNumber != null && canRequest) return const SeerrTitleAction(SeerrTitleActionKind.requestSeasons);
  if (kind == MediaKind.show && canRequest && state.hasMissingSeasons) {
    return const SeerrTitleAction(SeerrTitleActionKind.requestSeasons);
  }
  if (state.subscribed && state.subscriptionSeasonNumber == null) {
    if (state.subscriptionIs4k == true && state.status != 5 && canRequest && state.own == null && state.other == null) {
      return const SeerrTitleAction(SeerrTitleActionKind.request);
    }
    return const SeerrTitleAction(SeerrTitleActionKind.notificationsOn);
  }
  if (state.status == 5) {
    if (state.other4k != null && state.canSubscribe4k) return const SeerrTitleAction(SeerrTitleActionKind.notify4k);
    if (canRequest4k && state.status4k != 5 && state.status4k != 6 && state.own4k == null && state.other4k == null) {
      return const SeerrTitleAction(SeerrTitleActionKind.request4k);
    }
    return const SeerrTitleAction(SeerrTitleActionKind.available);
  }
  if (canRequest && state.own == null && state.other == null && state.own4k != null) {
    return const SeerrTitleAction(SeerrTitleActionKind.request);
  }
  if (canRequest4k &&
      state.own != null &&
      state.own4k == null &&
      state.other4k == null &&
      state.status4k != 5 &&
      state.status4k != 6) {
    return const SeerrTitleAction(SeerrTitleActionKind.request4k);
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
  if (canRequest) return const SeerrTitleAction(SeerrTitleActionKind.request);
  if (canRequest4k && state.status4k != 5 && state.status4k != 6) {
    return const SeerrTitleAction(SeerrTitleActionKind.request4k);
  }
  return null;
}

/// One existing action slot stays primary; a separate alert toggle remains
/// reachable when a season or quality request is also useful.
List<SeerrTitleAction> seerrTitleActions(
  SeerrCatalogSource source,
  MediaKind kind,
  SeerrRequestIntent? state, {
  int? seasonNumber,
}) {
  final primary = seerrTitleAction(source, kind, state, seasonNumber: seasonNumber);
  final actions = <SeerrTitleAction>[if (primary != null && primary.interactive) primary];
  if (state?.subscribed == true && primary?.kind != SeerrTitleActionKind.notificationsOn) {
    actions.add(const SeerrTitleAction(SeerrTitleActionKind.notificationsOn));
  }
  return actions;
}

/// Library titles already have Play; only missing seasons and an independent
/// 4K variant are useful there. An exact identity and server detail are
/// required before offering either action.
bool hasNewSeerrSeason(SeerrRequestIntent state, SeerrDetails details, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final known = state.seasons.map((season) => season.number).toSet();
  return (details.seasons ?? const <SeerrSeason>[]).any((season) {
    if (season.seasonNumber < 1 || (season.episodeCount ?? 0) < 1 || known.contains(season.seasonNumber)) return false;
    final aired = DateTime.tryParse(season.airDate ?? '');
    return aired != null && !aired.isAfter(today);
  });
}

/// A conservative opportunity computed from vanilla Seerr's standard title
/// detail. It has no viewer-specific claims or alert scope, so it must never
/// be used as a card badge or as quick-request authority.
class SeerrLegacyLibraryOpportunity {
  final bool missingSeasons;
  final bool request4k;

  const SeerrLegacyLibraryOpportunity({this.missingSeasons = false, this.request4k = false});

  factory SeerrLegacyLibraryOpportunity.fromDetails(
    SeerrCatalogSource source,
    MediaKind kind,
    SeerrDetails details,
    SeerrPublicSettings settings, {
    DateTime? now,
  }) {
    final info = details.mediaInfo;
    final product = source.client.session.product;
    final overall = info?.status(product) ?? SeerrMediaStatus.unknown;
    if (overall == SeerrMediaStatus.blocklisted) return const SeerrLegacyLibraryOpportunity();
    final active = (info?.requests ?? const <SeerrRequest>[]).where(
      (request) => request.status == SeerrRequestStatus.pending || request.status == SeerrRequestStatus.approved,
    );
    final today = now ?? DateTime.now();
    final missingSeasons =
        info != null &&
        kind == MediaKind.show &&
        source.canRequest(kind) &&
        (details.seasons ?? const <SeerrSeason>[]).any((season) {
          if (season.seasonNumber < 1 || (season.episodeCount ?? 0) < 1) return false;
          final aired = DateTime.tryParse(season.airDate ?? '');
          if (aired == null || aired.isAfter(today)) return false;
          final stored = info.seasons?.where((entry) => entry.seasonNumber == season.seasonNumber).firstOrNull;
          final status = stored?.status(product) ?? SeerrMediaStatus.unknown;
          if (status == SeerrMediaStatus.available ||
              status == SeerrMediaStatus.blocklisted ||
              status == SeerrMediaStatus.pending ||
              status == SeerrMediaStatus.processing) {
            return false;
          }
          return !active.any(
            (request) =>
                request.is4k != true &&
                (request.seasons == null ||
                    request.seasons!.isEmpty ||
                    request.seasons!.any((entry) => entry.seasonNumber == season.seasonNumber)),
          );
        });
    final qualityEnabled = kind == MediaKind.movie ? settings.movie4kEnabled : settings.series4kEnabled;
    final qualityStatus = info?.status4k(product) ?? SeerrMediaStatus.unknown;
    final request4k =
        source.canRequest4k(kind) &&
        qualityEnabled &&
        qualityStatus != SeerrMediaStatus.available &&
        qualityStatus != SeerrMediaStatus.blocklisted &&
        qualityStatus != SeerrMediaStatus.pending &&
        qualityStatus != SeerrMediaStatus.processing &&
        !active.any((request) => request.is4k == true);
    return SeerrLegacyLibraryOpportunity(missingSeasons: missingSeasons, request4k: request4k);
  }
}

SeerrTitleAction? librarySeerrTitleAction(
  SeerrCatalogSource source,
  MediaKind kind,
  SeerrRequestIntent? state, {
  bool hasNewSeason = false,
  SeerrLegacyLibraryOpportunity? legacy,
}) {
  if (!source.supportsTitleActions(kind)) return null;
  if (state == null) {
    if (legacy?.missingSeasons == true) return const SeerrTitleAction(SeerrTitleActionKind.requestSeasons);
    if (legacy?.request4k == true) return const SeerrTitleAction(SeerrTitleActionKind.request4k);
    return null;
  }
  if (state.status == 6) return null;
  if (kind == MediaKind.show &&
      source.canRequest(kind) &&
      state.canRequest &&
      state.status != 6 &&
      (state.hasMissingSeasons || hasNewSeason || state.status == 4)) {
    return const SeerrTitleAction(SeerrTitleActionKind.requestSeasons);
  }
  if (state.other4k != null && state.canSubscribe4k && !state.subscribed) {
    return const SeerrTitleAction(SeerrTitleActionKind.notify4k);
  }
  if (source.canRequest4k(kind) &&
      state.canRequest4k &&
      state.status4k != 5 &&
      state.status4k != 6 &&
      state.own4k == null &&
      state.other4k == null) {
    return const SeerrTitleAction(SeerrTitleActionKind.request4k);
  }
  if (state.subscribed) return const SeerrTitleAction(SeerrTitleActionKind.notificationsOn);
  return null;
}

List<SeerrTitleAction> librarySeerrTitleActions(
  SeerrCatalogSource source,
  MediaKind kind,
  SeerrRequestIntent? state, {
  bool hasNewSeason = false,
  SeerrLegacyLibraryOpportunity? legacy,
}) {
  final primary = librarySeerrTitleAction(source, kind, state, hasNewSeason: hasNewSeason, legacy: legacy);
  final actions = <SeerrTitleAction>[if (primary != null && primary.interactive) primary];
  if (state?.subscribed == true && primary?.kind != SeerrTitleActionKind.notificationsOn) {
    actions.add(const SeerrTitleAction(SeerrTitleActionKind.notificationsOn));
  }
  return actions;
}

Future<void> performSeerrTitleAction(
  BuildContext context, {
  required SeerrCatalogSource source,
  required MediaKind kind,
  required int tmdbId,
  required String title,
  required SeerrTitleAction action,
  int? seasonNumber,
  VoidCallback? onRequestSubmitted,
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
      final message = action.kind == SeerrTitleActionKind.notificationsOn
          ? t.seerr.notificationsDisabled
          : seasonNumber != null
          ? t.seerr.notificationsEnabledSeason(season: seasonNumber)
          : action.kind == SeerrTitleActionKind.notify4k
          ? t.seerr.notificationsEnabled4k
          : t.seerr.notificationsEnabled;
      showSuccessSnackBar(context, message);
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
        onRequestSubmitted?.call();
        showSuccessSnackBar(context, t.seerr.requestSubmitted);
      }
    } on SeerrApiException catch (e) {
      if (context.mounted) showErrorSnackBar(context, e.message);
      unawaited(source.client.intents.refresh(kind, tmdbId));
    } catch (e) {
      appLogger.w('Seerr: quick request failed', error: e);
      if (context.mounted) {
        showErrorSnackBar(context, t.seerr.requestFailed(error: localizedErrorReason(e)));
      }
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
    onSubmitted: onRequestSubmitted,
  );
}
