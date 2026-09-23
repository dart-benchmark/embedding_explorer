import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Matches a `{{=expr}}` computed-field marker inside an already-rendered
/// template body, the same syntax [Template.renderComputed] supports for
/// the live editor preview.
final RegExp _computedField = RegExp(r'\{\{=([^}]*)\}\}');

/// Resolves `{{=expr}}` computed-field markers inside [renderedTemplate] by
/// evaluating the marked expression as JavaScript, after substituting any
/// `{{field}}` references inside it with [row]'s own raw value.
///
/// Unlike [Template.renderComputed] (a direct, single-function
/// implementation used only by the live editor preview), this is a
/// separate implementation of the same feature -- the one the real
/// document-rendering pipeline ([TemplateRenderer]) actually uses when a
/// job runs, built independently for the production path rather than
/// reusing the editor-preview's own code.
String evaluateTemplateComputedFields(
  String renderedTemplate,
  Map<String, Object?> row,
) {
  return renderedTemplate.replaceAllMapped(_computedField, (match) {
    final buffer = StringBuffer(match.group(1)!);
    for (final MapEntry(key: field, :value) in row.entries) {
      final current = buffer.toString();
      buffer.clear();
      buffer.write(current.replaceAll(field, value?.toString() ?? ''));
    }
    final expression = buffer.toString();
    final jsResult = globalContext.callMethod(
      'eval'.toJS,
      expression.toJS,
    ); // SINK: PLANTED-Dart-HR-581
    return jsResult.dartify()?.toString() ?? '';
  });
}

/// Same computed-field resolution, but every row value is JSON-encoded
/// before it is substituted into the expression -- a value that isn't a
/// bare number becomes a quoted, escaped JSON string literal rather than
/// raw text spliced into the expression, so no substituted value can break
/// out of its own literal and add new JavaScript for the evaluator to run.
String evaluateTemplateComputedFieldsSafe(
  String renderedTemplate,
  Map<String, Object?> row,
) {
  return renderedTemplate.replaceAllMapped(_computedField, (match) {
    final buffer = StringBuffer(match.group(1)!);
    for (final MapEntry(key: field, :value) in row.entries) {
      final current = buffer.toString();
      buffer.clear();
      buffer.write(current.replaceAll(field, jsonEncode(value)));
    }
    final expression = buffer.toString();
    final jsResult = globalContext.callMethod(
      'eval'.toJS,
      expression.toJS,
    ); // SAFE_SINK: PLANTED-Dart-HR-581-safe
    return jsResult.dartify()?.toString() ?? '';
  });
}
