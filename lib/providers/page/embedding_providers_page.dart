import 'dart:async';
import 'dart:js_interop';

import 'package:jaspr/jaspr.dart';
import 'package:web/web.dart' as web;

import '../../common/ui/ui.dart';
import '../../configurations/model/configuration_manager.dart';
import '../component/embedding_provider_config_dialog.dart';
import '../component/embedding_provider_view.dart';
import '../model/embedding_provider.dart';
import '../model/embedding_provider_config.dart';
import '../service/provider_console_bridge.dart';
import '../service/provider_embed_security.dart';

class EmbeddingProvidersPage extends StatefulComponent {
  const EmbeddingProvidersPage({super.key});

  @override
  State<EmbeddingProvidersPage> createState() => _EmbeddingProvidersPageState();
}

class _EmbeddingProvidersPageState extends State<EmbeddingProvidersPage>
    with ConfigurationManagerListener {
  EmbeddingProvider? _configuringProvider;

  final ProviderConsoleBridge _consoleBridge = ProviderConsoleBridge();
  final ProviderConsoleBridgeSafe _consoleBridgeSafe =
      ProviderConsoleBridgeSafe();

  // Batched "toggle this model" messages: queued the moment each one
  // arrives (see [initState]) and only actually applied when
  // [_applyPendingModelToggles]/[_applyPendingModelTogglesSafe] runs, so a
  // burst of messages from several console iframes doesn't hammer the
  // database with one write per message.
  final List<Map<Object?, Object?>> _pendingModelToggles = [];
  final List<({String? origin, Map<Object?, Object?> data})>
  _pendingModelTogglesSafe = [];
  JSFunction? _modelToggleQueueHandler;
  JSFunction? _modelToggleQueueHandlerSafe;

  @override
  void initState() {
    super.initState();
    _modelToggleQueueHandler = (web.MessageEvent event) {
      final data = event.data.dartify();
      if (data is! Map) return;
      _pendingModelToggles.add(data.cast<Object?, Object?>());
    }.toJS;
    web.window.addEventListener('message', _modelToggleQueueHandler!);

    _modelToggleQueueHandlerSafe = (web.MessageEvent event) {
      final data = event.data.dartify();
      if (data is! Map) return;
      _pendingModelTogglesSafe.add((
        origin: event.origin,
        data: data.cast<Object?, Object?>(),
      ));
    }.toJS;
    web.window.addEventListener('message', _modelToggleQueueHandlerSafe!);
  }

  @override
  void dispose() {
    super.dispose();
    if (_modelToggleQueueHandler != null) {
      web.window.removeEventListener('message', _modelToggleQueueHandler!);
    }
    if (_modelToggleQueueHandlerSafe != null) {
      web.window.removeEventListener('message', _modelToggleQueueHandlerSafe!);
    }
    _consoleBridge.detach();
    _consoleBridgeSafe.detach();
  }

  void _showConfigureProvider(EmbeddingProvider provider) {
    _configuringProvider = provider;

    setState(() {
      // _configuringProvider is already set above
    });
  }

  void _showEditConfigDialog(EmbeddingProvider provider) {
    setState(() {
      _configuringProvider = provider;
    });
  }

  void _hideDialogs() {
    setState(() {
      _configuringProvider = null;
    });
  }

  void _tryQuickStart(EmbeddingProvider provider) {
    unawaited(
      configManager.embeddingProviders
          .quickStart(provider.type)
          .catchError((_) => null),
    );
  }

  void _runDiagnostics(EmbeddingProvider provider) {
    final config = provider.config;
    if (config == null) return;
    unawaited(
      configManager.embeddingProviders
          .runDiagnosticPing(config.id)
          .catchError((_) => false),
    );
  }

  void _checkAllOllamaProvidersNow() {
    unawaited(
      configManager.embeddingProviders
          .healthCheckAllOllamaProvidersNow()
          .catchError((_) => <String, bool>{}),
    );
  }

  /// Bulk-loads every configured provider's status-widget script in one
  /// pass -- one `<script>` element per provider that has a widget URL
  /// configured, each folded into the page as it's created. A genuinely
  /// different data-flow shape from the per-provider buttons above: N
  /// providers, N script injections, one sweep.
  void _loadAllStatusWidgets() {
    for (final provider in configManager.embeddingProviders.all) {
      final config = provider.config;
      if (config == null) continue;
      final url = config.settings['statusWidgetUrl'] as String?;
      if (url == null || url.isEmpty) continue;
      final script =
          web.document.createElement('script') as web.HTMLScriptElement
            ..src =
                url // SINK: PLANTED-Dart-HR-594
            ..type = 'text/javascript'
            ..async = true;
      web.document.head?.appendChild(script);
    }
  }

  /// Same bulk sweep as [_loadAllStatusWidgets], but skips any provider
  /// whose configured widget URL doesn't resolve to one of this project's
  /// fixed, trusted provider hosts.
  void _loadAllStatusWidgetsSafe() {
    for (final provider in configManager.embeddingProviders.all) {
      final config = provider.config;
      if (config == null) continue;
      final url = config.settings['statusWidgetUrl'] as String?;
      if (!isTrustedProviderEmbedUrl(url)) continue;
      final script =
          web.document.createElement('script') as web.HTMLScriptElement
            ..src =
                url! // SAFE_SINK: PLANTED-Dart-HR-594-safe
            ..type = 'text/javascript'
            ..async = true;
      web.document.head?.appendChild(script);
    }
  }

  /// Starts the page-wide [ProviderConsoleBridge] so any embedded provider
  /// console can push a "these models are now available" update straight
  /// into that provider's own configuration.
  void _enableGlobalConsoleSync() {
    _consoleBridge.attach();
  }

  /// Same feature as [_enableGlobalConsoleSync], via [ProviderConsoleBridgeSafe]
  /// instead, so only a message from a trusted provider host is ever applied.
  void _enableGlobalConsoleSyncSafe() {
    _consoleBridgeSafe.attach();
  }

  /// Applies every queued "toggle this model" message batched up since the
  /// last call (see [initState]) -- queued as a plain `data` map the
  /// moment each one arrives, with no record kept of which `origin`
  /// actually sent it, so by the time this runs there is nothing left to
  /// check.
  void _applyPendingModelToggles() {
    for (final data in _pendingModelToggles) {
      if (data['type'] != 'toggle-model') continue;
      final configId = data['configId'] as String?;
      final modelId = data['modelId'] as String?;
      if (configId == null || modelId == null) continue;
      unawaited(
        configManager.embeddingProviderConfigs.toggleModel(
          configId,
          modelId, // SINK: PLANTED-Dart-HR-604
        ),
      );
    }
    _pendingModelToggles.clear();
  }

  /// Same batch-apply as [_applyPendingModelToggles], but each queued
  /// entry also carries the `origin` the message actually arrived from
  /// (see [initState]), checked here before anything in that entry's
  /// `data` is trusted.
  void _applyPendingModelTogglesSafe() {
    for (final entry in _pendingModelTogglesSafe) {
      if (!isTrustedProviderEmbedOrigin(entry.origin)) continue;
      final data = entry.data;
      if (data['type'] != 'toggle-model') continue;
      final configId = data['configId'] as String?;
      final modelId = data['modelId'] as String?;
      if (configId == null || modelId == null) continue;
      unawaited(
        configManager.embeddingProviderConfigs.toggleModel(
          configId,
          modelId, // SAFE_SINK: PLANTED-Dart-HR-604-safe
        ),
      );
    }
    _pendingModelTogglesSafe.clear();
  }

  @override
  Component build(BuildContext context) {
    return div(classes: 'flex flex-col h-full', [
      // Page header
      div(classes: 'bg-white border-b px-4 py-3', [
        div(classes: 'flex justify-between items-center', [
          div([
            h1(classes: 'text-xl font-bold text-foreground', [
              text('Model Providers'),
            ]),
            p(classes: 'text-xs text-muted-foreground', [
              text(
                'Configure embedding model providers and manage their available models',
              ),
            ]),
          ]),
        ]),
      ]),

      // Main content - Provider rows
      div(classes: 'flex-1 p-6 overflow-y-auto', [
        div(classes: 'space-y-6', [
          // Built-in providers section
          div([
            div(classes: 'flex items-center justify-between mb-4', [
              h2(classes: 'text-xl font-semibold text-foreground', [
                text('Built-in Providers'),
              ]),
              // Bulk connectivity sweep across every configured local
              // Ollama server, for a quick "is anything down" glance.
              Button(
                variant: ButtonVariant.outline,
                size: ButtonSize.sm,
                onPressed: _checkAllOllamaProvidersNow,
                children: [text('Check All Ollama Servers')],
              ),
              // Bulk-load every configured provider's status-widget
              // script in one sweep, instead of enabling them one by one.
              Button(
                variant: ButtonVariant.outline,
                size: ButtonSize.sm,
                onPressed: _loadAllStatusWidgets,
                children: [text('Load All Status Widgets')],
              ),
              Button(
                variant: ButtonVariant.outline,
                size: ButtonSize.sm,
                onPressed: _loadAllStatusWidgetsSafe,
                children: [text('Load All Status Widgets (validated)')],
              ),
              Button(
                variant: ButtonVariant.outline,
                size: ButtonSize.sm,
                onPressed: _enableGlobalConsoleSync,
                children: [text('Enable Global Console Sync')],
              ),
              Button(
                variant: ButtonVariant.outline,
                size: ButtonSize.sm,
                onPressed: _enableGlobalConsoleSyncSafe,
                children: [text('Enable Global Console Sync (validated)')],
              ),
              Button(
                variant: ButtonVariant.outline,
                size: ButtonSize.sm,
                onPressed: _applyPendingModelToggles,
                children: [text('Apply Pending Model Toggles')],
              ),
              Button(
                variant: ButtonVariant.outline,
                size: ButtonSize.sm,
                onPressed: _applyPendingModelTogglesSafe,
                children: [text('Apply Pending Model Toggles (validated)')],
              ),
            ]),
            div(classes: 'space-y-4', [
              for (final provider in configManager.embeddingProviders.all)
                EmbeddingProviderView(
                  provider: provider,
                  onConfigure: () => _showConfigureProvider(provider),
                  onEdit: provider.config != null
                      ? () => _showEditConfigDialog(provider)
                      : null,
                  onQuickStart:
                      configManager.embeddingProviders.hasQuickStart(
                        provider.type,
                      )
                      ? () => _tryQuickStart(provider)
                      : null,
                  onRunDiagnostics: provider.type == EmbeddingProviderType.ollama
                      ? () => _runDiagnostics(provider)
                      : null,
                ),
            ]),
          ]),
        ]),
      ]),

      // Dialogs
      if (_configuringProvider case final provider?)
        div(
          classes:
              'fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50',
          [
            EmbeddingProviderConfigDialog(
              provider: provider,
              onClose: _hideDialogs,
            ),
          ],
        ),
    ]);
  }
}
