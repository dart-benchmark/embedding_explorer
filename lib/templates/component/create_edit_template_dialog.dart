import 'package:jaspr/jaspr.dart';

import '../../common/ui/ui.dart';
import '../../configurations/model/configuration_manager.dart';
import '../model/embedding_template.dart';
import '../service/computed_field_resolver.dart';
import 'template_editor.dart';
import 'template_editor_model.dart';

final class CreateEditTemplateDialog extends StatefulComponent {
  CreateEditTemplateDialog({required this.template, required this.onClose});

  final EmbeddingTemplate? template;
  final VoidCallback onClose;

  bool get isEditing => template != null;

  @override
  State<StatefulComponent> createState() => _CreateEditDialogState();
}

final class _CreateEditDialogState extends State<CreateEditTemplateDialog>
    with ConfigurationManagerListener {
  late final TemplateEditorModel model = TemplateEditorModel(
    configManager: configManager,
    initialTemplate: component.template,
  );

  static final RegExp _computedField = RegExp(r'\{\{=([^}]*)\}\}');

  /// Result of the last "Compute ID" preview action, whichever resolver it
  /// was run with.
  String? _computedIdPreview;

  @override
  void initState() {
    super.initState();

    // Allow time for the DOM to render so that we can find the Editor container.
    context.binding.addPostFrameCallback(() {
      model.init();
    });
  }

  @override
  void dispose() {
    model.dispose();
    super.dispose();
  }

  void _saveTemplate() {
    final templateId =
        component.template?.id ?? configManager.embeddingTemplates.generateId();
    final template = model.createConfig(templateId);

    configManager.embeddingTemplates.upsert(template);
    component.onClose();
  }

  /// Resolves the ID template's `{{=expr}}` computed marker (if any)
  /// against the current sample row via [JsEvalComputedFieldResolver] --
  /// which concrete resolver gets dispatched is the only thing that
  /// decides whether attacker-influenceable row content can ever reach a
  /// JavaScript evaluator here.
  void _previewComputedIdWithJsEngine() {
    final idTemplate = model.idEditor.value.value;
    final row = model.sampleRow;
    final match = _computedField.firstMatch(idTemplate.rawTemplate);
    if (match == null || row == null) return;
    setState(() {
      _computedIdPreview = resolveAndEvaluateComputedId(
        const JsEvalComputedFieldResolver(),
        match.group(1)!,
        row,
      );
    });
  }

  /// Same computed-ID preview, but dispatched via
  /// [SafeArithmeticComputedFieldResolver] instead -- only numeric row
  /// values ever reach the expression the evaluator runs.
  void _previewComputedIdWithSafeEngine() {
    final idTemplate = model.idEditor.value.value;
    final row = model.sampleRow;
    final match = _computedField.firstMatch(idTemplate.rawTemplate);
    if (match == null || row == null) return;
    setState(() {
      _computedIdPreview = resolveAndEvaluateComputedIdSafe(
        const SafeArithmeticComputedFieldResolver(),
        match.group(1)!,
        row,
      );
    });
  }

  @override
  Component build(BuildContext context) {
    return Dialog(
      onClose: component.onClose,
      maxWidth: 'max-w-4xl',
      builder: (_) =>
          ListenableBuilder(listenable: model, builder: _buildContent),
    );
  }

  Component _buildContent(BuildContext context) {
    return DialogContent(
      children: [
        DialogHeader(
          children: [
            div(classes: 'flex justify-between items-center', [
              DialogTitle(
                children: [
                  text(
                    component.isEditing ? 'Edit Template' : 'Create Template',
                  ),
                ],
              ),
              IconButton(
                onPressed: component.onClose,
                icon: FaIcon(FaIcons.solid.close),
              ),
            ]),
            DialogDescription(
              children: [
                text(
                  component.isEditing
                      ? 'Update your embedding template with Monaco editor'
                      : 'Create a new embedding template with Monaco editor',
                ),
              ],
            ),
          ],
        ),

        // Error message if any
        if (model.error.value case final error?)
          div(classes: 'mb-6 bg-red-50 border border-red-200 rounded-md p-4', [
            div(classes: 'flex', [
              div(classes: 'flex-shrink-0', [
                svg(
                  classes: 'h-5 w-5 text-red-400',
                  attributes: {'fill': 'currentColor', 'viewBox': '0 0 20 20'},
                  [
                    path(
                      attributes: {
                        'fill-rule': 'evenodd',
                        'd':
                            'M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z',
                        'clip-rule': 'evenodd',
                      },
                      [],
                    ),
                  ],
                ),
              ]),
              div(classes: 'ml-3', [
                h3(classes: 'text-sm font-medium text-red-800', [
                  text('Template Error'),
                ]),
                div(classes: 'mt-2 text-sm text-red-700', [
                  p([text(error)]),
                ]),
                div(classes: 'mt-4', [
                  button(
                    classes:
                        'bg-red-100 px-2 py-1 text-sm font-medium text-red-800 rounded-md hover:bg-red-200 focus:outline-none focus:ring-2 focus:ring-red-500 focus:ring-offset-2',
                    events: {'click': (_) => model.dismissError()},
                    [text('Dismiss')],
                  ),
                ]),
              ]),
            ]),
          ]),

        // Template Editor
        TemplateEditor(model: model),

        // Computed ID preview -- test the ID template's `{{=expr}}` field
        // (if any) against the current sample row with either engine.
        div(classes: 'mt-4 space-y-2', [
          div(classes: 'flex items-center space-x-2', [
            Button(
              variant: ButtonVariant.outline,
              size: ButtonSize.sm,
              onPressed: _previewComputedIdWithJsEngine,
              children: [text('Compute ID (JS engine)')],
            ),
            Button(
              variant: ButtonVariant.ghost,
              size: ButtonSize.sm,
              onPressed: _previewComputedIdWithSafeEngine,
              children: [text('Compute ID (safe engine)')],
            ),
          ]),
          if (_computedIdPreview case final preview?)
            div(classes: 'text-sm text-muted-foreground', [
              text('Computed ID: $preview'),
            ]),
        ]),

        DialogFooter(
          children: [
            div(classes: 'flex justify-end space-x-3 w-full', [
              Button(
                variant: ButtonVariant.outline,
                onPressed: component.onClose,
                children: [text('Cancel')],
              ),
              Button(
                onPressed: model.validate() ? _saveTemplate : null,
                children: [text(component.isEditing ? 'Update' : 'Create')],
              ),
            ]),
          ],
        ),
      ],
    );
  }
}
