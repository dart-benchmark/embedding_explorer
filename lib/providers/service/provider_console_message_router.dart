import 'dart:async';

import 'package:web/web.dart' as web;

import '../../configurations/model/configuration_manager.dart';
import 'provider_embed_security.dart';

/// Decides whether a `message` event's own `origin` should be trusted
/// before [routeProviderConsoleMessage]/[routeProviderConsoleMessageSafe]
/// act on its `data`. Two real implementations exist so a caller can pick
/// which trust posture to apply -- whether an incoming message is ever
/// actually honored depends entirely on which concrete policy a caller
/// constructs and passes in, never on any branch taken inside either
/// routing function itself.
abstract interface class MessageOriginPolicy {
  bool isTrusted(String origin);
}

/// Trusts every origin unconditionally -- the "raw" policy, always wired
/// in by [routeProviderConsoleMessage]'s own caller.
class PermissiveMessageOriginPolicy implements MessageOriginPolicy {
  const PermissiveMessageOriginPolicy();

  @override
  bool isTrusted(String origin) => true;
}

/// Trusts only an origin resolving to one of this project's fixed,
/// trusted provider hosts -- always wired in by
/// [routeProviderConsoleMessageSafe]'s own caller.
class AllowListMessageOriginPolicy implements MessageOriginPolicy {
  const AllowListMessageOriginPolicy();

  @override
  bool isTrusted(String origin) => isTrustedProviderEmbedOrigin(origin);
}

/// Applies a `settings-resync` message pushed by an embedded provider
/// console/dashboard iframe -- a full replacement of that provider's
/// stored `settings`, letting a console-side "restore my settings" action
/// resync the app without the visitor re-entering every field by hand.
/// Always wired to a [PermissiveMessageOriginPolicy] by its caller
/// ([DashboardPage._enableConsoleMessageRouting]).
void routeProviderConsoleMessage(
  MessageOriginPolicy policy,
  web.MessageEvent event,
) {
  if (!policy.isTrusted(event.origin)) return;
  final data = event.data.dartify();
  if (data is! Map) return;
  if (data['type'] != 'settings-resync') return;
  final configId = data['configId'] as String?;
  final settings = data['settings'];
  if (configId == null || settings is! Map) return;
  ConfigurationManager.instance.embeddingProviderConfigs
      .updateConfig(
        configId,
        settings: Map<String, dynamic>.from(
          settings,
        ), // SINK: PLANTED-Dart-HR-603
      )
      .ignore();
}

/// Structurally identical to [routeProviderConsoleMessage] -- kept as its
/// own named entry point (rather than reusing the same function) so the
/// "validated" listener always goes through a call site that reads, at a
/// glance, as the checked path; always wired to an
/// [AllowListMessageOriginPolicy] by its caller
/// ([DashboardPage._enableConsoleMessageRoutingSafe]).
void routeProviderConsoleMessageSafe(
  MessageOriginPolicy policy,
  web.MessageEvent event,
) {
  if (!policy.isTrusted(event.origin)) return;
  final data = event.data.dartify();
  if (data is! Map) return;
  if (data['type'] != 'settings-resync') return;
  final configId = data['configId'] as String?;
  final settings = data['settings'];
  if (configId == null || settings is! Map) return;
  ConfigurationManager.instance.embeddingProviderConfigs
      .updateConfig(
        configId,
        settings: Map<String, dynamic>.from(
          settings,
        ), // SAFE_SINK: PLANTED-Dart-HR-603-safe
      )
      .ignore();
}
