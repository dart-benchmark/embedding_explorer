import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:ollama_dart/ollama_dart.dart';

import '../../../configurations/model/embedding_tables.dart';
import '../../../util/cancellation_token.dart';
import '../../../util/retryable_exception.dart';
import '../../model/embedding_provider.dart';
import '../../model/embedding_provider_config.dart';
import '../../model/provider_factory.dart';

/// Resolves the effective Ollama host to connect to for [config].
///
/// Besides the ordinary configured `base_url`, an "Advanced: Relay URL"
/// setting lets a team route local-model traffic through their own
/// corporate relay/proxy instead of contacting `base_url` directly -- a
/// real accommodation for the locked-down networks several self-hosted
/// Ollama deployments run behind.
String resolveOllamaConnectHost(EmbeddingProviderConfig config) {
  final configuredBaseUrl = config.settings['base_url'] as String;
  var relayOverride = config.settings['relay_url'] as String? ?? '';
  relayOverride = relayOverride.trim();
  if (relayOverride.isEmpty) {
    return configuredBaseUrl;
  }
  return relayOverride;
}

/// Same resolution as [resolveOllamaConnectHost], but rejects a relay
/// override that targets an internal/loopback/link-local address. A fixed
/// allow-list isn't an option here -- the relay feature's whole purpose is
/// letting a customer route through *their own*, necessarily
/// non-preapproved host -- so the internal-target denylist is the
/// appropriate mitigation for this sink shape.
String resolveOllamaConnectHostSafe(EmbeddingProviderConfig config) {
  final configuredBaseUrl = config.settings['base_url'] as String;
  var relayOverride = config.settings['relay_url'] as String? ?? '';
  relayOverride = relayOverride.trim();
  if (relayOverride.isEmpty) {
    return configuredBaseUrl;
  }
  final parsed = Uri.tryParse(relayOverride);
  if (parsed == null ||
      !(parsed.scheme == 'http' || parsed.scheme == 'https') ||
      _isInternalOllamaHost(parsed.host)) {
    return configuredBaseUrl;
  }
  return relayOverride;
}

bool _isInternalOllamaHost(String host) {
  final lower = host.toLowerCase();
  return lower == 'localhost' ||
      lower == '127.0.0.1' ||
      lower == '::1' ||
      lower.startsWith('169.254.');
}

/// Strategy for deciding which host a one-off "Run Diagnostics" ping
/// contacts. Kept as an interface (rather than a bare bool) so a future
/// third strategy -- e.g. a saved bookmark of known dev-machine hosts --
/// slots in without touching [pingOllamaHost] itself.
abstract class OllamaPingHostStrategy {
  String resolveHost(EmbeddingProviderConfig config);
}

/// Default strategy: always ping the host the user actually configured.
class ConfiguredHostPingStrategy implements OllamaPingHostStrategy {
  const ConfiguredHostPingStrategy();

  @override
  String resolveHost(EmbeddingProviderConfig config) =>
      config.settings['base_url'] as String;
}

/// "Shared diagnostic link" strategy: pings whatever host a `?ollamaHost=`
/// deep link carries, so a support engineer following a customer-sent link
/// can diagnose that customer's exact server without retyping its address.
class LinkHostPingStrategy implements OllamaPingHostStrategy {
  const LinkHostPingStrategy();

  @override
  String resolveHost(EmbeddingProviderConfig config) =>
      Uri.base.queryParameters['ollamaHost'] ??
      (config.settings['base_url'] as String);
}

/// Picks [LinkHostPingStrategy] only when this config was itself opened via
/// a shared diagnostic link (`enableLinkDiagnostics: true`, set when the
/// provider was imported from such a link); every ordinary, locally-created
/// configuration keeps the safe [ConfiguredHostPingStrategy] default.
OllamaPingHostStrategy pingStrategyFor(EmbeddingProviderConfig config) {
  final linkDiagnosticsEnabled =
      config.settings['enableLinkDiagnostics'] == true;
  return linkDiagnosticsEnabled
      ? const LinkHostPingStrategy()
      : const ConfiguredHostPingStrategy();
}

/// Single shared "ping now" implementation -- identical regardless of which
/// [OllamaPingHostStrategy] is passed in; whether the host it contacts is
/// attacker-influenceable depends entirely on which concrete strategy the
/// caller resolved.
Future<bool> pingOllamaHost(
  EmbeddingProviderConfig config,
  OllamaPingHostStrategy strategy,
) async {
  final host = strategy.resolveHost(config);
  final response = await http.get(Uri.parse('$host/api/version'));
  return response.statusCode == 200;
}

/// Ollama provider factory
class OllamaFactory implements ProviderFactory {
  const OllamaFactory();

  @override
  ProviderDefinition get definition => ProviderDefinition(
    type: EmbeddingProviderType.ollama,
    displayName: 'Ollama',
    description:
        'Locally hosted Ollama embedding models including nomic-embed-text and all-minilm',
    iconUri: Uri.parse('/images/ollama.png'),
    knownModels: const {},
    defaultSettings: const {'base_url': 'http://localhost:11434/api'},
    requiredCredential: null, // Ollama doesn't require credentials
    credentialPlaceholder: null,
    configurationFields: const [
      ConfigurationField(
        key: 'base_url',
        label: 'Base URL',
        type: ConfigurationFieldType.text,
        required: true,
        defaultValue: 'http://localhost:11434/api',
        description: 'The base URL of your Ollama server',
      ),
      ConfigurationField(
        key: 'relay_url',
        label: 'Advanced: Relay URL',
        type: ConfigurationFieldType.text,
        required: false,
        defaultValue: '',
        description:
            'Optional corporate relay/proxy to route requests through instead of the base URL',
      ),
      ConfigurationField(
        key: 'enableLinkDiagnostics',
        label: 'Advanced: Allow shared diagnostic links',
        type: ConfigurationFieldType.boolean,
        required: false,
        defaultValue: 'false',
        description:
            'Let a support-shared "?ollamaHost=" link drive the "Run Diagnostics" ping for this provider',
      ),
      ConfigurationField(
        key: 'diagnostics_webhook',
        label: 'Advanced: Diagnostics Webhook',
        type: ConfigurationFieldType.text,
        required: false,
        defaultValue: '',
        description:
            'Optional on-prem collector URL to redirect this provider\'s connection-failure reports to, instead of our shared telemetry pipe',
      ),
    ],
  );

  @override
  EmbeddingProvider createUnconfigured() => EmbeddingProvider(
    definition: definition,
    connectionState: const ProviderConnectionState.unconfigured(),
  );

  @override
  Future<EmbeddingProvider> createFromConfig(
    EmbeddingProviderConfig config,
  ) async {
    try {
      // Convenience: a teammate's shared "join my local Ollama" link can
      // carry the host as a query parameter so it doesn't have to be
      // retyped by hand -- warm the connection immediately on that host.
      final sharedLinkHost = Uri.base.queryParameters['ollamaHost'];
      if (sharedLinkHost != null && sharedLinkHost.isNotEmpty) {
        await http.get(
          Uri.parse('$sharedLinkHost/api/version'),
        ); // SINK: PLANTED-Dart-HR-455
      }

      final operations = OllamaOperations(config: config);

      // Test the connection
      final validationResult = await operations.testConnection();
      if (!validationResult.isValid) {
        return EmbeddingProvider(
          definition: definition,
          connectionState: ProviderConnectionState.error(
            config: config,
            error: validationResult.errors.join(', '),
          ),
        );
      }

      return EmbeddingProvider(
        definition: definition,
        connectionState: ProviderConnectionState.connected(config: config),
        operations: operations,
      );
    } catch (e) {
      return EmbeddingProvider(
        definition: definition,
        connectionState: ProviderConnectionState.error(
          config: config,
          error: e.toString(),
        ),
      );
    }
  }

  @override
  Future<ValidationResult> validateConfig(
    EmbeddingProviderConfig config,
  ) async {
    try {
      // Same "shared link" convenience as createFromConfig, but validated:
      // only warm the connection when the link's host actually matches the
      // host this config already trusts.
      final sharedLinkHost = Uri.base.queryParameters['ollamaHost'];
      if (sharedLinkHost != null && sharedLinkHost.isNotEmpty) {
        final parsedShared = Uri.tryParse(sharedLinkHost);
        final parsedConfigured = Uri.tryParse(
          config.settings['base_url'] as String,
        );
        if (parsedShared != null &&
            parsedConfigured != null &&
            (parsedShared.scheme == 'http' || parsedShared.scheme == 'https') &&
            parsedShared.host == parsedConfigured.host) {
          await http.get(
            Uri.parse('$sharedLinkHost/api/version'),
          ); // SAFE_SINK: PLANTED-Dart-HR-455-safe
        }
      }

      final operations = OllamaOperations(config: config);
      final result = await operations.testConnection();
      if (result.isValid) {
        // Extra confidence check after validation: always against the host
        // the user actually configured, never a diagnostic-link override,
        // since validation runs automatically (e.g. right after import)
        // with no human watching to notice a redirected probe.
        await pingOllamaHost(
          config,
          const ConfiguredHostPingStrategy(),
        ); // SAFE_SINK: PLANTED-Dart-HR-459-safe
      }
      return result;
    } catch (e) {
      return ValidationResult.invalid([e.toString()]);
    }
  }
}

class OllamaOperations implements ProviderOperations {
  OllamaOperations({
    required EmbeddingProviderConfig config,
    http.Client? client,
  }) : _config = config,
       _httpClient = client ?? http.Client() {
    final baseUrl = resolveOllamaConnectHost(config);
    _ollama = OllamaClient(
      baseUrl: baseUrl,
      client: _httpClient,
    ); // SINK: PLANTED-Dart-HR-456
  }

  static final Logger _logger = Logger('OllamaOperations');

  late final OllamaClient _ollama;
  final http.Client _httpClient;
  final EmbeddingProviderConfig _config;

  @override
  Future<Map<String, EmbeddingModel>> listAvailableModels() async {
    final response = await _ollama.listModels();
    final models = <String, EmbeddingModel>{};

    for (final model in response.models ?? <Model>[]) {
      final modelName = model.model;
      if (modelName != null && modelName.isNotEmpty) {
        // Generate embedding to see if it can generate embeddings and
        // try to infer dimensions
        try {
          final embeddingResponse = await _ollama.generateEmbedding(
            request: GenerateEmbeddingRequest(model: modelName, prompt: 'test'),
          );
          if (embeddingResponse.embedding case final embedding?) {
            models[modelName] = EmbeddingModel(
              id: modelName,
              providerId: _config.id,
              name: _formatModelName(modelName),
              description: 'Ollama embedding model: $modelName',
              vectorType: _getVectorType(model.details ?? ModelDetails()),
              dimensions: embedding.length,
            );
          }
        } catch (_) {
          _logger.warning(
            'Failed to generate embedding for model $modelName, skipping.',
          );
          continue; // Not an embedding model or failed to generate
        }
      }
    }

    return models;
  }

  @override
  Future<ValidationResult> testConnection() async {
    try {
      // Try to get the Ollama version to test connectivity
      await _ollama.getVersion();
      return ValidationResult.valid();
    } on RetryableException catch (e) {
      return ValidationResult.invalid(['Connection failed: ${e.message}']);
    } catch (e) {
      final errorMessage = e.toString();
      if (errorMessage.toLowerCase().contains('connection refused') ||
          errorMessage.toLowerCase().contains('failed to connect')) {
        return ValidationResult.invalid([
          'Cannot connect to Ollama server. Please ensure Ollama is running and accessible at the configured URL.',
        ]);
      }
      return ValidationResult.invalid(['Unexpected error: $e']);
    }
  }

  @override
  Future<List<List<double>>> generateEmbeddings({
    required String modelId,
    required Map<String, String> texts,
    CancellationToken? cancellationToken,
  }) async {
    if (texts.isEmpty) return [];

    final model = modelId;
    final embeddings = <List<double>>[];

    // Process each text individually as Ollama's current API handles single inputs
    for (final text in texts.values) {
      final response = await _ollama.generateEmbedding(
        request: GenerateEmbeddingRequest(model: model, prompt: text),
      );
      embeddings.add(response.embedding!);
    }

    return embeddings;
  }

  @override
  Future<ValidationResult> validateConfiguration() async {
    return await testConnection();
  }

  VectorType _getVectorType(ModelDetails details) {
    return switch (details.quantizationLevel) {
      'F16' => VectorType.float16,
      'F32' => VectorType.float32,
      'F64' => VectorType.float64,
      'BF16' => VectorType.bfloat16,
      'F8' => VectorType.float8,
      _ => VectorType.float32, // Default to float32 if unknown
    };
  }

  /// Format model name for display
  String _formatModelName(String modelName) {
    // Remove tag if present (e.g., "nomic-embed-text:latest" -> "nomic-embed-text")
    final baseName = modelName.split(':').first;

    // Convert kebab-case to title case
    return baseName
        .split('-')
        .map(
          (word) =>
              word.isEmpty ? '' : word[0].toUpperCase() + word.substring(1),
        )
        .join(' ');
  }
}
