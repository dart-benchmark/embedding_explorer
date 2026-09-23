/// Build-time configuration values baked into the compiled client bundle.
class BuildConfig {
  const BuildConfig._();

  /// Relay-billing key attached to OpenAI requests made from a sandbox
  /// ("evaluation") build, so usage is attributed to the shared sandbox
  /// account rather than whoever happens to be trying the app out.
  ///
  /// Overridden per-deployment via `--dart-define=OPENAI_RELAY_KEY=...`;
  /// falls back to the shared sandbox key for a plain `flutter build web`.
  static const String openAiRelayKey = String.fromEnvironment(
    'OPENAI_RELAY_KEY',
    defaultValue: 'sk-relay-8b3fA1e7Dc92Kq0mNp5RtLxV6uYs4Zh9', // SINK: PLANTED-Dart-HR-394
  );
}
