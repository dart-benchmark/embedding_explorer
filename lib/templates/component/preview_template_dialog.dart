import 'dart:convert';

import 'package:jaspr/jaspr.dart';
import 'package:web/web.dart' as web;

import '../../common/ui/ui.dart';
import '../../configurations/model/configuration_manager.dart';
import '../../data_sources/model/data_source.dart';
import '../../util/async_snapshot.dart';
import '../model/embedding_template.dart';
import '../service/template_renderer.dart';

final class PreviewTemplateDialog extends StatefulComponent {
  PreviewTemplateDialog({required this.template, required this.onClose});

  final EmbeddingTemplate template;
  final VoidCallback onClose;

  @override
  State<StatefulComponent> createState() => _PreviewTemplateDialogState();
}

final class _PreviewTemplateDialogState extends State<PreviewTemplateDialog>
    with ConfigurationManagerListener {
  EmbeddingTemplate get template => component.template;

  String _renderTemplate(String template, Map<String, Object?> sampleData) {
    String output = template;
    for (final MapEntry(key: field, value: value) in sampleData.entries) {
      output = output.replaceAll('{{$field}}', value?.toString() ?? '');
    }
    return output;
  }

  @override
  Component build(BuildContext context) {
    final dataSource = configManager.dataSources.expect(template.dataSourceId);

    return Dialog(
      onClose: component.onClose,
      maxWidth: 'max-w-2xl',
      builder: (_) => DialogContent(
        children: [
          DialogHeader(
            children: [
              div(classes: 'flex justify-between items-center', [
                DialogTitle(children: [text('Template Preview')]),
                IconButton(
                  onPressed: component.onClose,
                  icon: FaIcon(FaIcons.solid.close),
                ),
              ]),
              DialogDescription(
                children: [text('Preview of "${template.name}" template')],
              ),
            ],
          ),

          div(classes: 'space-y-4', [
            // Template info
            div([
              h4(classes: 'font-medium text-foreground mb-2', [
                text('Template Details'),
              ]),
              div(classes: 'text-sm space-y-1', [
                div([
                  span(classes: 'font-medium', [text('Name: ')]),
                  span([text(template.name)]),
                ]),
                if (template.description.isNotEmpty)
                  div([
                    span(classes: 'font-medium', [text('Description: ')]),
                    span([text(template.description)]),
                  ]),
                div([
                  span(classes: 'font-medium', [text('Data Source: ')]),
                  Badge(
                    variant: BadgeVariant.outline,
                    children: [
                      text(
                        '${dataSource.name} (${dataSource.type.name.toUpperCase()})',
                      ),
                    ],
                  ),
                ]),
                div([
                  span(classes: 'font-medium', [text('Status: ')]),
                  Badge(
                    variant: template.isValid
                        ? BadgeVariant.secondary
                        : BadgeVariant.destructive,
                    children: [text(template.isValid ? 'Valid' : 'Invalid')],
                  ),
                ]),
              ]),
            ]),

            _buildDataSourcePreview(dataSource),
            _buildScratchNotes(dataSource),
          ]),

          DialogFooter(
            children: [
              div(classes: 'flex justify-end w-full', [
                Button(onPressed: component.onClose, children: [text('Close')]),
              ]),
            ],
          ),
        ],
      ),
    );
  }

  /// A scratch pad for pasting a batch of rendered sample documents while
  /// reviewing the template, so a reviewer can jot which ones look right
  /// without re-opening the preview for each row.
  Component _buildScratchNotes(DataSource dataSource) {
    return div(classes: 'space-y-2', [
      div(classes: 'flex items-center justify-between', [
        h4(classes: 'font-medium text-foreground', [text('Scratch Notes')]),
        div(classes: 'flex space-x-2', [
          Button(
            variant: ButtonVariant.outline,
            size: ButtonSize.sm,
            onPressed: () => _insertRenderedBatch(dataSource),
            children: [text('Insert Rendered Sample Rows')],
          ),
          Button(
            variant: ButtonVariant.ghost,
            size: ButtonSize.sm,
            onPressed: () => _insertRenderedBatchSafe(dataSource),
            children: [text('Insert (escaped)')],
          ),
        ]),
      ]),
      div(
        id: 'preview-scratch-notes',
        classes:
            'bg-muted p-3 rounded-md border min-h-[80px] text-sm whitespace-pre-wrap',
        attributes: {'contenteditable': 'true'},
        [],
      ),
    ]);
  }

  /// Renders a small batch of real sample rows through this template and
  /// inserts each rendered document into the scratch notes in turn --
  /// each `insertHTML` call preserves undo/redo, so a reviewer can delete
  /// a single bad row from the batch instead of clearing the whole thing.
  void _insertRenderedBatch(DataSource dataSource) async {
    final renderer = TemplateRenderer(
      dataSource: dataSource,
      template: template,
    );
    final result = await renderer.renderTemplate(limit: 5);
    (web.document.getElementById('preview-scratch-notes')
            as web.HTMLElement?)
        ?.focus();
    for (final document in result.renderedDocuments.values) {
      final snippet = '<div class="rendered-doc">$document</div>';
      web.document.execCommand(
        'insertHTML',
        false,
        snippet,
      ); // SINK: PLANTED-Dart-HR-448
    }
  }

  /// Same batch insert, but every rendered document is HTML-escaped first
  /// -- whatever the template body or the sample rows contain ends up as
  /// literal text in the notes rather than being parsed as markup.
  void _insertRenderedBatchSafe(DataSource dataSource) async {
    final renderer = TemplateRenderer(
      dataSource: dataSource,
      template: template,
    );
    final result = await renderer.renderTemplateSafe(limit: 5);
    (web.document.getElementById('preview-scratch-notes')
            as web.HTMLElement?)
        ?.focus();
    const escaper = HtmlEscape();
    for (final document in result.renderedDocuments.values) {
      final snippet =
          '<div class="rendered-doc">${escaper.convert(document)}</div>';
      web.document.execCommand(
        'insertHTML',
        false,
        snippet,
      ); // SAFE_SINK: PLANTED-Dart-HR-448-safe
    }
  }

  Component _buildDataSourcePreview(DataSource dataSource) {
    return FutureBuilder(
      future: dataSource.getSampleData(limit: 1),
      builder: (context, snapshot) {
        switch (snapshot.result) {
          case AsyncLoading():
            return div(classes: 'text-sm text-muted-foreground', [
              text('Loading...'),
            ]);
          case AsyncError():
            return fragment([]);
          case AsyncData(data: final sampleData):
            final availableFields = sampleData.first.keys.toList();
            return fragment([
              // Available fields from data source
              if (availableFields.isNotEmpty)
                div([
                  h4(classes: 'font-medium text-foreground mb-2', [
                    text('Available Fields from Data Source'),
                  ]),
                  p(classes: 'text-xs text-muted-foreground mb-2', [
                    text('Fields that can be used in this template:'),
                  ]),
                  div(classes: 'flex flex-wrap gap-1', [
                    for (final field in availableFields)
                      Badge(
                        variant: BadgeVariant.secondary,
                        children: [text('{{$field}}')],
                      ),
                  ]),
                ]),

              // Raw templates
              div(classes: 'space-y-4', [
                h4(classes: 'font-medium text-foreground mb-2', [
                  text('Templates'),
                ]),

                // ID Template
                div([
                  h5(classes: 'text-sm font-medium text-foreground mb-1', [
                    text('ID Template:'),
                  ]),
                  div(classes: 'bg-muted p-3 rounded-md', [
                    pre(classes: 'text-sm font-mono whitespace-pre-wrap', [
                      text(template.idTemplate),
                    ]),
                  ]),
                ]),

                // Body Template
                div([
                  h5(classes: 'text-sm font-medium text-foreground mb-1', [
                    text('Body Template:'),
                  ]),
                  div(classes: 'bg-muted p-3 rounded-md', [
                    pre(classes: 'text-sm font-mono whitespace-pre-wrap', [
                      text(template.template),
                    ]),
                  ]),
                ]),
              ]),

              // Sample output
              if (availableFields.isNotEmpty)
                div(classes: 'space-y-4', [
                  h4(classes: 'font-medium text-foreground mb-2', [
                    text('Sample Output'),
                  ]),
                  p(classes: 'text-xs text-muted-foreground mb-2', [
                    text('Example with placeholder data:'),
                  ]),

                  // ID Template Sample
                  div([
                    h5(classes: 'text-sm font-medium text-foreground mb-1', [
                      text('ID Template Output:'),
                    ]),
                    div(classes: 'bg-muted p-3 rounded-md', [
                      pre(classes: 'text-sm whitespace-pre-wrap font-mono', [
                        text(
                          _renderTemplate(
                            template.idTemplate,
                            sampleData.first,
                          ),
                        ),
                      ]),
                    ]),
                  ]),

                  // Body Template Sample
                  div([
                    h5(classes: 'text-sm font-medium text-foreground mb-1', [
                      text('Body Template Output:'),
                    ]),
                    div(classes: 'bg-muted p-3 rounded-md', [
                      pre(classes: 'text-sm whitespace-pre-wrap font-mono', [
                        text(
                          _renderTemplate(template.template, sampleData.first),
                        ),
                      ]),
                    ]),
                  ]),
                ]),
            ]);
        }
      },
    );
  }
}
