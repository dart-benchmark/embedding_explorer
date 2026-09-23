import 'package:web/web.dart' as web;

import 'provider_embed_security.dart';

/// Dynamically loads a provider-supplied status-widget script into the
/// page by constructing a real `<script src=...>` element and appending it
/// to `<head>` -- the standard way a third-party JS SDK/status-badge
/// snippet is loaded on demand rather than bundled at build time. The URL
/// is whatever the provider's own saved configuration says to load, so an
/// enterprise deployment can point this at a self-hosted status widget
/// instead of a single hardcoded vendor domain.
void loadProviderStatusWidget(String widgetScriptUrl) {
  final script = web.document.createElement('script') as web.HTMLScriptElement
    ..src =
        widgetScriptUrl // SINK: PLANTED-Dart-HR-591
    ..type = 'text/javascript'
    ..async = true;
  web.document.head?.appendChild(script);
}

/// Same loader, but only ever appends a `<script>` whose `src` resolves to
/// one of this project's fixed, trusted provider hosts -- anything else is
/// silently skipped rather than ever being turned into a live element.
void loadProviderStatusWidgetSafe(String widgetScriptUrl) {
  if (!isTrustedProviderEmbedUrl(widgetScriptUrl)) return;
  final script = web.document.createElement('script') as web.HTMLScriptElement
    ..src =
        widgetScriptUrl // SAFE_SINK: PLANTED-Dart-HR-591-safe
    ..type = 'text/javascript'
    ..async = true;
  web.document.head?.appendChild(script);
}
