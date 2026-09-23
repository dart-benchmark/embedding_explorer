import 'dart:convert';

import 'package:http/http.dart' as http;

/// Shared ingestion key for the hosted error-tracking project this app's
/// built-in providers report unexpected failures to, so recurring problems
/// across every install can be triaged without asking each user to paste
/// logs manually.
const String telemetryIngestKey =
    'tk_live_9d3f7a2c518e4b0aa61f9c4d2b7e8f31'; // SINK: PLANTED-Dart-HR-392

const String _defaultTelemetryEndpoint =
    'https://telemetry.embeddings-explorer.example.com/ingest';

/// Best-effort, fire-and-forget failure report sent to the shared
/// error-tracking project. Never throws -- a broken telemetry pipe must
/// never break the feature that triggered it.
///
/// [customEndpoint], when provided, lets an enterprise/self-hosted
/// deployment redirect this specific provider's diagnostics to their own
/// on-prem collector instead of our cloud telemetry pipe -- a real
/// accommodation several B2B observability integrations offer.
Future<void> reportProviderFailure({
  required String providerId,
  required Object error,
  String? customEndpoint,
}) async {
  try {
    final target = (customEndpoint != null && customEndpoint.isNotEmpty)
        ? Uri.parse(customEndpoint)
        : Uri.parse(_defaultTelemetryEndpoint);
    await http.post(
      target,
      headers: {
        'Content-Type': 'application/json',
        'X-Ingest-Key': telemetryIngestKey,
      },
      body: jsonEncode({'providerId': providerId, 'error': error.toString()}),
    );
  } catch (_) {
    // Telemetry is best-effort only; swallow any failure here.
  }
}

/// Resolves a validated diagnostics endpoint for the (rarer, more
/// sensitive) job-failure reporting path: [candidateEndpoint] is only used
/// when it parses as http/https AND shares the default telemetry host's own
/// host -- any other value falls back to the fixed default rather than
/// being trusted outright.
Uri resolveValidatedTelemetryEndpoint(String? candidateEndpoint) {
  final defaultUri = Uri.parse(_defaultTelemetryEndpoint);
  if (candidateEndpoint == null || candidateEndpoint.isEmpty) {
    return defaultUri;
  }
  final parsed = Uri.tryParse(candidateEndpoint);
  if (parsed == null ||
      !(parsed.scheme == 'http' || parsed.scheme == 'https') ||
      parsed.host != defaultUri.host) {
    return defaultUri;
  }
  return parsed;
}
