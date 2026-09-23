import 'package:jaspr/jaspr.dart';
import 'package:web/web.dart' as web;

import '../../common/monaco/monaco_editor.dart';
import '../../common/ui/ui.dart';
import 'template_editor_model.dart';

/// A component that provides a Monaco-based editor for embedding templates
/// with intellisense support for available data fields.
class TemplateEditor extends StatelessComponent {
  TemplateEditor({required this.model}) : super(key: ValueKey(model));

  final TemplateEditorModel model;

  @override
  Component build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (_) => TemplateEditorView(model: model),
    );
  }
}

class TemplateEditorView extends StatefulComponent {
  const TemplateEditorView({super.key, required this.model});

  final TemplateEditorModel model;

  @override
  State<TemplateEditorView> createState() => _TemplateEditorViewState();
}

class _TemplateEditorViewState extends State<TemplateEditorView> {
  TemplateEditorModel get model => component.model;

  @override
  Component build(BuildContext context) {
    return div(classes: 'space-y-6', [
      _buildBasicFields(),
      _buildFieldManagement(),
      ValueListenableBuilder(
        listenable: model.selectedDataSourceId,
        builder: (_, dataSourceId) {
          return div(classes: dataSourceId.isEmpty ? 'hidden' : null, [
            _buildTemplateInput(),
          ]);
        },
      ),
    ]);
  }

  Component _buildBasicFields() {
    return div(classes: 'space-y-4', [
      div(classes: 'grid grid-cols-1 md:grid-cols-2 gap-4', [
        div(classes: 'space-y-2', [
          Label(
            htmlFor: 'template-name',
            className: 'text-foreground',
            children: [text('Name *')],
          ),
          ValueListenableBuilder(
            listenable: model.name,
            builder: (context, name) {
              return Input.text(
                id: 'template-name',
                placeholder: 'Enter template name',
                value: name,
                onChange: (value) => model.updateName(value),
              );
            },
          ),
        ]),
        div(classes: 'space-y-2', [
          Label(
            htmlFor: 'template-desc',
            className: 'text-foreground',
            children: [text('Description')],
          ),
          ValueListenableBuilder(
            listenable: model.description,
            builder: (context, description) {
              return Input.text(
                id: 'template-desc',
                placeholder: 'Brief description',
                value: description,
                onChange: (value) => model.updateDescription(value),
              );
            },
          ),
        ]),
      ]),
    ]);
  }

  Component _buildFieldManagement() {
    return div(classes: 'space-y-4', [
      div([
        h3(classes: 'text-lg font-medium text-foreground mb-2', [
          text('Data Source'),
        ]),
        p(classes: 'text-sm text-muted-foreground', [
          text(
            'Select a data source to load available fields for your template.',
          ),
        ]),
      ]),

      // Data source selector
      div(classes: 'space-y-2', [
        Label(className: 'text-foreground', children: [text('Data Source *')]),
        ValueListenableBuilder(
          listenable: model.selectedDataSourceId,
          builder: (context, selectedId) {
            final dataSources = model.configManager.dataSourceConfigs.all;
            return Select(
              value: selectedId,
              placeholder: 'Select a data source...',
              onChange: (value) => model.updateDataSource(value),
              children: [
                for (final dataSource in dataSources)
                  Option(
                    value: dataSource.id,
                    children: [
                      text(
                        '${dataSource.name} (${dataSource.type.name.toUpperCase()})',
                      ),
                    ],
                  ),
              ],
            );
          },
        ),
      ]),

      // Show data source fields if available
      if (model.schemaFields.isNotEmpty)
        div([
          Label(
            className: 'text-foreground mb-2',
            children: [text('Available Fields')],
          ),
          p(classes: 'text-xs text-muted-foreground mb-2', [
            text('These fields are available from your selected data source.'),
          ]),
          div(classes: 'flex flex-wrap gap-2', [
            for (final field in model.schemaFields)
              span(
                classes:
                    'px-2 py-1 text-xs rounded border border-gray-300 text-gray-700',
                [text('{{$field}}')],
              ),
          ]),
        ]),
    ]);
  }

  Component _buildTemplateInput() {
    return div(classes: 'space-y-4', [
      h3(classes: 'text-lg font-medium text-foreground mb-2', [
        text('Document Template'),
      ]),
      p(classes: 'text-sm text-muted-foreground mb-4', [
        text(
          'Use {{field}} syntax to reference fields. The editor provides auto-completion and syntax highlighting.',
        ),
      ]),
      _buildIdTemplateEditor(),
      _buildTemplateEditor(),
    ]);
  }

  Component _buildIdTemplateEditor() {
    return div([
      Label(className: 'text-foreground mb-2', children: [text('ID *')]),
      p(classes: 'text-sm text-muted-foreground mb-4', [
        text('The unique identifier for documents generated by this template.'),
      ]),
      MonacoEditor(model: model.idEditor),
      ValueListenableBuilder(
        listenable: model.idEditor.value,
        builder: (context, _) {
          return div(classes: 'mt-4', [
            h4(classes: 'text-sm font-medium text-foreground mb-2', [
              text('ID Template Preview'),
            ]),
            div(classes: 'bg-muted p-3 rounded-md border min-h-[50px]', [
              pre(classes: 'text-sm whitespace-pre-wrap font-mono', [
                text(model.idPreviewText),
              ]),
            ]),
          ]);
        },
      ),
    ]);
  }

  Component _buildTemplateEditor() {
    return div([
      Label(className: 'text-foreground mb-2', children: [text('Body *')]),
      p(classes: 'text-sm text-muted-foreground mb-4', [
        text(
          'The main content template for documents, e.g. what gets embedded by the model.',
        ),
      ]),
      MonacoEditor(model: model.editor),
      ValueListenableBuilder(
        listenable: model.editor.value,
        builder: (context, _) {
          return div(classes: 'mt-4', [
            h4(classes: 'text-sm font-medium text-foreground mb-2', [
              text('Body Template Preview'),
            ]),
            div(classes: 'bg-muted p-3 rounded-md border min-h-[50px]', [
              pre(classes: 'text-sm whitespace-pre-wrap font-mono', [
                text(model.previewText),
              ]),
            ]),
            _buildComputedFieldPreview(),
            _buildNotesSection(),
          ]);
        },
      ),
    ]);
  }

  /// Live preview of any `{{=expr}}` computed fields the body template
  /// defines, evaluated against the selected data source's sample row.
  Component _buildComputedFieldPreview() {
    return div(classes: 'mt-4', [
      h4(classes: 'text-sm font-medium text-foreground mb-2', [
        text('Computed Field Preview'),
      ]),
      div(classes: 'bg-muted p-3 rounded-md border min-h-[50px]', [
        pre(classes: 'text-sm whitespace-pre-wrap font-mono', [
          text(model.computedPreviewText),
        ]),
      ]),
    ]);
  }

  /// A free-form scratch area for jotting notes about this template while
  /// designing it -- with a couple of "Insert Preview" shortcuts so the
  /// current rendered preview doesn't have to be retyped by hand.
  Component _buildNotesSection() {
    return div(classes: 'mt-4 space-y-2', [
      div(classes: 'flex items-center justify-between', [
        Label(className: 'text-foreground', children: [text('Notes')]),
        div(classes: 'flex space-x-2', [
          Button(
            variant: ButtonVariant.outline,
            size: ButtonSize.sm,
            onPressed: _insertPreviewIntoNotes,
            children: [text('Insert Preview')],
          ),
          Button(
            variant: ButtonVariant.ghost,
            size: ButtonSize.sm,
            onPressed: _insertPreviewIntoNotesPlainText,
            children: [text('Insert Preview (plain text)')],
          ),
        ]),
      ]),
      div(
        id: 'template-notes',
        classes:
            'bg-white p-3 rounded-md border min-h-[80px] text-sm whitespace-pre-wrap',
        attributes: {'contenteditable': 'true'},
        [],
      ),
    ]);
  }

  /// Inserts the current rendered preview into the notes area at the
  /// caret, preserving undo/redo -- the preview text is whatever the
  /// template's own Monaco body renders against the selected data
  /// source's sample row, so it can contain anything the template author
  /// or the sample row's own content happens to produce.
  void _insertPreviewIntoNotes() {
    (web.document.getElementById('template-notes') as web.HTMLElement?)
        ?.focus();
    web.document.execCommand(
      'insertHTML',
      false,
      model.previewText,
    ); // SINK: PLANTED-Dart-HR-447
  }

  /// Same shortcut, but inserted as literal text -- the browser never
  /// parses the preview as markup this way, so nothing in the template or
  /// the sample data can inject an element into the notes.
  void _insertPreviewIntoNotesPlainText() {
    (web.document.getElementById('template-notes') as web.HTMLElement?)
        ?.focus();
    web.document.execCommand(
      'insertText',
      false,
      model.previewText,
    ); // SAFE_SINK: PLANTED-Dart-HR-447-safe
  }
}
