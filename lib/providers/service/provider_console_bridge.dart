import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../../configurations/model/configuration_manager.dart';
import 'provider_embed_security.dart';

/// Wires a single, page-wide `message` listener that lets any embedded
/// provider console iframe (see
/// `EmbeddingProviderView._showProviderConsole`) push a live
/// "these models are now available" update straight into that provider's
/// own persisted configuration -- without the visitor having to leave the
/// console and manually toggle the models on again.
///
/// The raw event is only ever handled here; the actual mutation always
/// happens one call away, in [ConfigurationManager.embeddingProviderConfigs]
/// -- a different file/class from this one.
class ProviderConsoleBridge {
  JSFunction? _handler;

  /// Starts listening. ANY origin can post a `models-enabled` message and
  /// have it applied -- the message's own `origin` is never inspected.
  void attach() {
    _handler = (web.MessageEvent event) {
      final data = event.data.dartify();
      if (data is! Map) return;
      _applyModelsEnabledMessage(data);
    }.toJS;
    web.window.addEventListener('message', _handler!);
  }

  void detach() {
    if (_handler != null) {
      web.window.removeEventListener('message', _handler!);
      _handler = null;
    }
  }

  void _applyModelsEnabledMessage(Map<Object?, Object?> data) {
    if (data['type'] != 'models-enabled') return;
    final configId = data['configId'] as String?;
    final modelIds = data['modelIds'];
    if (configId == null || modelIds is! List) return;
    final existing = ConfigurationManager.instance.embeddingProviderConfigs
        .getById(configId);
    if (existing == null) return;
    final merged = Set<String>.of(existing.enabledModels)
      ..addAll(modelIds.whereType<String>());
    ConfigurationManager.instance.embeddingProviderConfigs
        .updateConfig(
          configId,
          enabledModels: merged, // SINK: PLANTED-Dart-HR-602
        )
        .ignore();
  }
}

/// Same bridge as [ProviderConsoleBridge], but only ever applies a message
/// whose `origin` resolves to one of this project's fixed, trusted
/// provider hosts -- kept as its own class (rather than a flag on the
/// other one) so the validated listener always goes through a call site
/// that reads, at a glance, as the checked path.
class ProviderConsoleBridgeSafe {
  JSFunction? _handler;

  void attach() {
    _handler = (web.MessageEvent event) {
      if (!isTrustedProviderEmbedOrigin(event.origin)) return;
      final data = event.data.dartify();
      if (data is! Map) return;
      _applyModelsEnabledMessage(data);
    }.toJS;
    web.window.addEventListener('message', _handler!);
  }

  void detach() {
    if (_handler != null) {
      web.window.removeEventListener('message', _handler!);
      _handler = null;
    }
  }

  void _applyModelsEnabledMessage(Map<Object?, Object?> data) {
    if (data['type'] != 'models-enabled') return;
    final configId = data['configId'] as String?;
    final modelIds = data['modelIds'];
    if (configId == null || modelIds is! List) return;
    final existing = ConfigurationManager.instance.embeddingProviderConfigs
        .getById(configId);
    if (existing == null) return;
    final merged = Set<String>.of(existing.enabledModels)
      ..addAll(modelIds.whereType<String>());
    ConfigurationManager.instance.embeddingProviderConfigs
        .updateConfig(
          configId,
          enabledModels: merged, // SAFE_SINK: PLANTED-Dart-HR-602-safe
        )
        .ignore();
  }
}
