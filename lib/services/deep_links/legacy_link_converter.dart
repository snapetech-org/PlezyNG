import 'deep_link.dart';

enum LegacyLinkConversionError { empty, invalidUri, unsupportedScheme, unsupportedRoute }

class LegacyLinkConversionResult {
  const LegacyLinkConversionResult._({this.output, this.error, this.schemeChanged = false});

  const LegacyLinkConversionResult.success({required String output, required bool schemeChanged})
    : this._(output: output, schemeChanged: schemeChanged);

  const LegacyLinkConversionResult.failure(LegacyLinkConversionError error) : this._(error: error);

  final String? output;
  final LegacyLinkConversionError? error;
  final bool schemeChanged;

  bool get isSuccess => output != null;
}

/// Produces a canonical-link preview without dispatching or opening the link.
///
/// The original URI text is retained after the scheme delimiter. Parsing is
/// used only to validate that the rewritten link matches the current grammar.
LegacyLinkConversionResult previewLegacyLink(String input) {
  final value = input.trim();
  if (value.isEmpty) {
    return const LegacyLinkConversionResult.failure(LegacyLinkConversionError.empty);
  }
  if (RegExp(r'[\u0000-\u0020\u007f]').hasMatch(value)) {
    return const LegacyLinkConversionResult.failure(LegacyLinkConversionError.invalidUri);
  }

  final schemeMatch = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*):').firstMatch(value);
  final uri = Uri.tryParse(value);
  if (schemeMatch == null || uri == null || !uri.hasScheme || value.length == schemeMatch.end) {
    return const LegacyLinkConversionResult.failure(LegacyLinkConversionError.invalidUri);
  }

  final sourceScheme = schemeMatch.group(1)!.toLowerCase();
  const supportedSchemes = {DeepLink.scheme, 'plezyng', 'plezxyng', 'plezy'};
  if (!supportedSchemes.contains(sourceScheme)) {
    return const LegacyLinkConversionResult.failure(LegacyLinkConversionError.unsupportedScheme);
  }

  final colon = schemeMatch.end - 1;
  final canonical = '${DeepLink.scheme}${value.substring(colon)}';
  if (DeepLink.tryParse(canonical) == null) {
    return const LegacyLinkConversionResult.failure(LegacyLinkConversionError.unsupportedRoute);
  }

  return LegacyLinkConversionResult.success(output: canonical, schemeChanged: canonical != value);
}
