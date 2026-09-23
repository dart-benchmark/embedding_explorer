/// Hosts explicitly trusted to serve a provider's own web console or a
/// vendor-supplied status-widget script. Every safe twin in the "provider
/// console/widget" feature (see [EmbeddingProviderView], the config dialog's
/// vendor-dashboard preview, and [ProviderWidgetUrlResolver]) checks against
/// this fixed set -- nothing outside it may ever become a live
/// `<iframe>`/`<script>` element, regardless of what a provider's own saved
/// configuration claims. Kept as one shared, hardcoded allow-list so every
/// caller enforces the exact same trust boundary.
const Set<String> trustedProviderEmbedHosts = {
  'platform.openai.com',
  'status.openai.com',
  'aistudio.google.com',
};

/// Whether [url] is safe to turn into a live `<iframe src>`/`<script src>`:
/// it must parse, use `https`, and resolve to a host in
/// [trustedProviderEmbedHosts]. Used by every safe twin in this feature --
/// never by a vulnerable one.
bool isTrustedProviderEmbedUrl(String? url) {
  if (url == null || url.isEmpty) return false;
  final parsed = Uri.tryParse(url);
  if (parsed == null) return false;
  if (parsed.scheme != 'https') return false;
  return trustedProviderEmbedHosts.contains(parsed.host.toLowerCase());
}

/// Whether [origin] -- a `MessageEvent.origin` string such as
/// `https://studio.outerbase.com`, with no path -- is one of this
/// project's fixed, trusted provider hosts. Used by every safe
/// `window.onmessage`/`addEventListener('message', ...)` handler in the
/// "provider console/widget" feature so a postMessage listener enforces
/// the exact same trust boundary [isTrustedProviderEmbedUrl] already
/// enforces for iframe/script `src` values -- the same embedded consoles
/// and dashboards are both what gets loaded *and* who is allowed to talk
/// back. Never used by a vulnerable handler.
bool isTrustedProviderEmbedOrigin(String? origin) {
  if (origin == null || origin.isEmpty) return false;
  final parsed = Uri.tryParse(origin);
  if (parsed == null) return false;
  if (parsed.scheme != 'https') return false;
  return trustedProviderEmbedHosts.contains(parsed.host.toLowerCase());
}
