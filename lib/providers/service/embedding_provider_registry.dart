import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:jaspr/jaspr.dart';
import 'package:logging/logging.dart';

import '../../configurations/model/configuration_manager.dart';
import '../../credentials/model/credential.dart';
import '../../util/telemetry_reporter.dart';
import '../model/embedding_provider.dart';
import '../model/embedding_provider_config.dart';
import '../model/provider_factory.dart';
import 'builtin_providers/gemini_provider.dart';
import 'builtin_providers/ollama_provider.dart';
import 'builtin_providers/openai_provider.dart';

/// Registry that manages embedding provider instances.
///
/// This class maintains a registry of available provider factories and manages
/// provider instances. It listens to the ConfigurationManager and ensures
/// providers are properly connected, updated, and disposed when needed.
class EmbeddingProviderRegistry with ChangeNotifier {
  static final Logger _logger = Logger('EmbeddingProviderRegistry');

  final ConfigurationManager _configManager;
  final Map<String, EmbeddingProvider> _providers = {};
  final Map<String, Future<Map<String, EmbeddingModel>>> _availableModels = {};

  static final Map<EmbeddingProviderType, ProviderFactory> _factories = {
    EmbeddingProviderType.openai: const OpenAIFactory(),
    EmbeddingProviderType.gemini: const GeminiFactory(),
    EmbeddingProviderType.ollama: const OllamaFactory(),
  };

  EmbeddingProviderRegistry(this._configManager) {
    _configManager.embeddingProviderConfigs.addListener(_onConfigChanged);
  }

  /// Initialize the registry by loading existing configurations
  Future<void> initialize() async {
    final configs = _configManager.embeddingProviderConfigs.all;
    await Future.wait(configs.map(_tryLoadProvider));
  }

  /// Get all provider instances (configured and unconfigured)
  List<EmbeddingProvider> get all {
    final all = _collectAll().toList(growable: false);
    all.sort((a, b) {
      // Sort built-in providers first, then custom by name
      final aIsBuiltin = a.type != EmbeddingProviderType.custom;
      final bIsBuiltin = b.type != EmbeddingProviderType.custom;
      if (aIsBuiltin && !bIsBuiltin) return -1;
      if (!aIsBuiltin && bIsBuiltin) return 1;
      if (aIsBuiltin && bIsBuiltin) {
        return a.type.index.compareTo(b.type.index);
      }
      return a.displayName.compareTo(b.displayName);
    });
    return all;
  }

  Iterable<EmbeddingProvider> _collectAll() sync* {
    // First yield all configured providers
    yield* _providers.values;

    // Then yield unconfigured providers for types that aren't configured
    final configuredTypes = _providers.values.map((p) => p.type).toSet();
    for (final factory in _factories.values) {
      if (!configuredTypes.contains(factory.definition.type)) {
        yield factory.createUnconfigured();
      }
    }
  }

  /// Get a provider by ID (returns null if not found)
  EmbeddingProvider? get(String id) => _providers[id];

  /// Get a provider by ID (throws if not found)
  EmbeddingProvider expect(String id) {
    final provider = _providers[id];
    if (provider == null) {
      throw StateError('No provider found with ID: $id');
    }
    return provider;
  }

  /// Get connected providers only
  Iterable<EmbeddingProvider> get connected =>
      _providers.values.where((p) => p.isConnected);

  /// Configure a provider
  Future<EmbeddingProvider> configure(
    EmbeddingProviderConfig config, {
    bool saveConfig = true,
  }) async {
    final factory = _factories[config.type];
    if (factory == null) {
      throw StateError('No factory found for provider type: ${config.type}');
    }

    try {
      final provider = await factory.createFromConfig(config);
      _providers[config.id] = provider;

      // Save configuration if successfully connected and saveConfig is true
      if (saveConfig && provider.isConnected) {
        await _configManager.embeddingProviderConfigs.upsert(config);
      }

      notifyListeners();
      return provider;
    } catch (e, st) {
      // Failures are always logged locally first -- this is the safe
      // baseline behavior and needs no credential of any kind.
      _logger.warning(
        'Failed to configure provider ${config.id}',
        e,
        st,
      ); // SAFE_SINK: PLANTED-Dart-HR-392-safe
      // Also forward to the shared error-tracking project so recurring
      // failures are visible without asking every user for their logs.
      // An enterprise deployment can redirect this specific provider's
      // reports to their own on-prem collector via a per-provider setting.
      unawaited(
        reportProviderFailure(
          providerId: config.id,
          error: e,
          customEndpoint:
              config.settings['diagnostics_webhook']
                  as String?, // SINK: PLANTED-Dart-HR-457
        ),
      );

      // Create an error state provider
      final errorProvider = factory.createUnconfigured().copyWith(
        connectionState: ProviderConnectionState.error(
          config: config,
          error: e.toString(),
        ),
      );
      _providers[config.id] = errorProvider;
      notifyListeners();
      rethrow;
    }
  }

  /// Instantly configures [type] using this app's bundled trial credential,
  /// so a visitor can try a built-in provider with one click instead of
  /// first obtaining and typing in their own API key. Returns null if no
  /// trial credential is bundled for that provider type.
  Future<EmbeddingProvider?> quickStart(EmbeddingProviderType type) async {
    final config = _quickStartConfigFor(type);
    if (config == null) return null;
    return configure(config);
  }

  /// Whether [type] has a bundled trial credential to quick-start with, so
  /// callers (e.g. the "Try free demo" button) can hide themselves for a
  /// provider that has none instead of rendering a no-op control.
  bool hasQuickStart(EmbeddingProviderType type) =>
      _quickStartConfigFor(type) != null;

  /// Builds a ready-to-use "quick start" config for [type], or null when
  /// this provider has no bundled trial credential to quick-start with.
  EmbeddingProviderConfig? _quickStartConfigFor(EmbeddingProviderType type) {
    switch (type) {
      case EmbeddingProviderType.gemini:
        // Gemini has a genuine free tier, so a shared trial key is cheap
        // enough to bundle for instant, no-signup evaluation.
        const trialApiKey =
            'AIzaSyQk8f3TnStarter5Rv7WcHm2Bx9Ldp1'; // SINK: PLANTED-Dart-HR-393
        return EmbeddingProviderConfig.create(
          id: 'quickstart-${type.name}',
          type: type,
          credential: const Credential.apiKey(trialApiKey),
        );
      case EmbeddingProviderType.openai:
      case EmbeddingProviderType.ollama:
      case EmbeddingProviderType.custom:
        // No bundled trial credential for these -- the visitor must
        // configure their own key; nothing is ever quick-started for them.
        return null; // SAFE_SINK: PLANTED-Dart-HR-393-safe
    }
  }

  /// Remove a provider
  Future<void> remove(String id) async {
    _providers.remove(id);
    _availableModels.remove(id)?.ignore();
    await _configManager.embeddingProviderConfigs.remove(id);
    notifyListeners();
  }

  /// Get available models for a provider
  Future<Map<String, EmbeddingModel>> getAvailableModels(String providerId) {
    if (_availableModels[providerId] case final cached?) {
      return cached;
    }

    final provider = _providers[providerId];
    if (provider?.operationsOrNull case final ops?) {
      final future = ops.listAvailableModels().catchError((_) {
        _availableModels.remove(providerId);
        return provider?.knownModels ?? {};
      });
      _availableModels[providerId] = future;
      return future;
    }

    return Future.value(provider?.knownModels ?? {});
  }

  Future<void> _tryLoadProvider(EmbeddingProviderConfig config) async {
    try {
      // Don't save config when loading from config changes to avoid infinite loop
      await configure(config, saveConfig: false);
    } catch (e) {
      _logger.fine('Provider ${config.id} loaded with error: $e');
    }
  }

  /// Runs a one-off connectivity ping for [providerId], used by the
  /// "Run Diagnostics" action in the provider list. Only meaningful for
  /// Ollama-backed providers today -- other provider types don't expose a
  /// lightweight, credential-free ping endpoint.
  Future<bool> runDiagnosticPing(String providerId) async {
    final provider = _providers[providerId];
    final config = provider?.config;
    if (provider == null ||
        config == null ||
        provider.type != EmbeddingProviderType.ollama) {
      return false;
    }
    return pingOllamaHost(
      config,
      pingStrategyFor(config),
    ); // SINK: PLANTED-Dart-HR-459
  }

  /// Manually triggered "Check Now" bulk health check across every
  /// configured Ollama-backed provider, surfaced by the provider list's
  /// toolbar. Trusts each provider's fully-resolved connect host (including
  /// any advanced relay override) exactly as the live connection itself
  /// does, so the reported status matches what a real request would hit.
  Future<Map<String, bool>> healthCheckAllOllamaProvidersNow() async {
    final results = <String, bool>{};
    for (final provider in _providers.values) {
      if (provider.type != EmbeddingProviderType.ollama) continue;
      final config = provider.config;
      if (config == null) continue;

      final host = resolveOllamaConnectHost(config);
      final uri = Uri.parse(host).replace(path: '/api/tags');
      try {
        final response = await http.get(uri); // SINK: PLANTED-Dart-HR-458
        results[config.id] = response.statusCode == 200;
      } catch (_) {
        results[config.id] = false;
      }
    }
    return results;
  }

  /// Unattended background sweep (run on a timer, never from a user click)
  /// across every configured Ollama-backed provider. Runs with nobody
  /// watching, so -- unlike the manual "Check Now" action above -- it never
  /// honors a relay override that might redirect it off the customer's own
  /// network.
  Future<Map<String, bool>> scheduledOllamaHealthSweep() async {
    final results = <String, bool>{};
    for (final provider in _providers.values) {
      if (provider.type != EmbeddingProviderType.ollama) continue;
      final config = provider.config;
      if (config == null) continue;

      final host = resolveOllamaConnectHostSafe(config);
      final uri = Uri.parse(host).replace(path: '/api/tags');
      try {
        final response = await http.get(
          uri,
        ); // SAFE_SINK: PLANTED-Dart-HR-456-safe
        results[config.id] = response.statusCode == 200;
      } catch (_) {
        results[config.id] = false;
      }
    }
    return results;
  }

  @override
  void dispose() {
    _configManager.embeddingProviderConfigs.removeListener(_onConfigChanged);
    _providers.clear();
    _availableModels.clear();
    super.dispose();
  }

  void _onConfigChanged() {
    // Handle configuration changes
    final currentConfigs = _configManager.embeddingProviderConfigs.all;
    final currentIds = currentConfigs.map((c) => c.id).toSet();
    final providerIds = _providers.keys.toSet();

    // Remove deleted providers
    for (final id in providerIds.difference(currentIds)) {
      _providers.remove(id);
      _availableModels.remove(id)?.ignore();
    }

    // Add or update providers
    for (final config in currentConfigs) {
      unawaited(_tryLoadProvider(config));
    }

    notifyListeners();
  }
}
