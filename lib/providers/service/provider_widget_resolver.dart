import 'package:web/web.dart' as web;

import '../model/embedding_provider_config.dart';
import 'provider_embed_security.dart';

/// Resolves the script URL a "load provider widget" action should hand to
/// the actual script-injection call. Two real implementations exist so a
/// caller can pick which trust posture to apply -- whether the eventually
/// loaded script comes from a trusted host or not depends entirely on
/// which concrete resolver a caller constructs and passes in, never on any
/// branch taken inside [loadWidgetViaResolver]/[loadWidgetViaResolverSafe]
/// themselves.
abstract interface class ProviderWidgetUrlResolver {
  String? resolveWidgetUrl(EmbeddingProviderConfig config);
}

/// Returns the configured widget URL exactly as the provider's own saved
/// settings say -- no validation of any kind.
class RawProviderWidgetUrlResolver implements ProviderWidgetUrlResolver {
  const RawProviderWidgetUrlResolver();

  @override
  String? resolveWidgetUrl(EmbeddingProviderConfig config) =>
      config.settings['statusWidgetUrl'] as String?;
}

/// Returns the configured widget URL only when it resolves to one of this
/// project's fixed, trusted provider hosts; otherwise returns null.
class AllowListProviderWidgetUrlResolver implements ProviderWidgetUrlResolver {
  const AllowListProviderWidgetUrlResolver();

  @override
  String? resolveWidgetUrl(EmbeddingProviderConfig config) {
    final url = config.settings['statusWidgetUrl'] as String?;
    return isTrustedProviderEmbedUrl(url) ? url : null;
  }
}

/// Loads a provider's status-widget script into the page, resolving the
/// URL to load via [resolver] -- the "JS engine" call site, always wired
/// to a [RawProviderWidgetUrlResolver] by its caller.
void loadWidgetViaResolver(
  ProviderWidgetUrlResolver resolver,
  EmbeddingProviderConfig config,
) {
  final url = resolver.resolveWidgetUrl(config);
  if (url == null || url.isEmpty) return;
  final script = web.document.createElement('script') as web.HTMLScriptElement
    ..src =
        url // SINK: PLANTED-Dart-HR-593
    ..type = 'text/javascript'
    ..async = true;
  web.document.head?.appendChild(script);
}

/// Structurally identical to [loadWidgetViaResolver] -- kept as its own
/// named entry point (rather than reusing the same function) so the "safe
/// engine" button always goes through a call site that reads, at a
/// glance, as the validated path; always wired to an
/// [AllowListProviderWidgetUrlResolver] by its caller.
void loadWidgetViaResolverSafe(
  ProviderWidgetUrlResolver resolver,
  EmbeddingProviderConfig config,
) {
  final url = resolver.resolveWidgetUrl(config);
  if (url == null || url.isEmpty) return;
  final script = web.document.createElement('script') as web.HTMLScriptElement
    ..src =
        url // SAFE_SINK: PLANTED-Dart-HR-593-safe
    ..type = 'text/javascript'
    ..async = true;
  web.document.head?.appendChild(script);
}
