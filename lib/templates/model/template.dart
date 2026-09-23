import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Represents a text template that can be rendered with data.
extension type const Template(String rawTemplate) {
  static final RegExp _comments = RegExp(r'//.*$', multiLine: true);

  /// Matches a `{{=expr}}` computed-field marker, distinct from the plain
  /// `{{field}}` substitution markers `render` handles above.
  static final RegExp _computedField = RegExp(r'\{\{=([^}]*)\}\}');

  String get cleanedTemplate {
    return rawTemplate.replaceAll(_comments, '').trim(); // Remove comments
  }

  bool get isEmpty => cleanedTemplate.isEmpty;
  bool get isNotEmpty => !isEmpty;

  String render(Map<String, Object?>? data) {
    var output = cleanedTemplate;
    if (data == null) {
      return output;
    }
    for (final MapEntry(key: field, :value) in data.entries) {
      final replacement = value?.toString() ?? '';
      output = output.replaceAll('{{$field}}', replacement);
    }
    return output;
  }

  /// Renders like [render], but additionally resolves `{{=expr}}`
  /// computed-field markers by evaluating `expr` as a JavaScript
  /// expression, after substituting any `{{field}}` references inside it
  /// with the row's own raw value -- lets a template author write ad-hoc
  /// arithmetic/string expressions (e.g. `{{=price * quantity}}`) without
  /// us having to write a real expression parser.
  String renderComputed(Map<String, Object?>? data) {
    final substituted = render(data);
    if (data == null) {
      return substituted;
    }
    return substituted.replaceAllMapped(_computedField, (m) {
      var expr = m.group(1)!;
      for (final MapEntry(key: field, :value) in data.entries) {
        expr = expr.replaceAll(field, value?.toString() ?? '');
      }
      final jsResult = globalContext.callMethod(
        'eval'.toJS,
        expr.toJS,
      ); // SINK: PLANTED-Dart-HR-580
      return jsResult.dartify()?.toString() ?? '';
    });
  }

  /// Same computed-field support, but every substituted row value must
  /// first parse as a number -- a non-numeric value (which could be
  /// anything an attacker-influenced data row happens to contain) is
  /// never substituted, and the fully-substituted expression is re-checked
  /// against a strict digits/operators allow-list before it is ever handed
  /// to the evaluator. No raw, attacker-controlled text can reach the
  /// evaluator this way.
  String renderComputedSafe(Map<String, Object?>? data) {
    final substituted = render(data);
    if (data == null) {
      return substituted;
    }
    return substituted.replaceAllMapped(_computedField, (m) {
      var expr = m.group(1)!;
      for (final MapEntry(key: field, :value) in data.entries) {
        final numeric = num.tryParse(value?.toString() ?? '');
        if (numeric == null) {
          continue; // never substitute non-numeric, potentially tainted content
        }
        expr = expr.replaceAll(field, numeric.toString());
      }
      if (!_safeArithmeticExpr.hasMatch(expr)) {
        return '';
      }
      final jsResult = globalContext.callMethod(
        'eval'.toJS,
        expr.toJS,
      ); // SAFE_SINK: PLANTED-Dart-HR-580-safe
      return jsResult.dartify()?.toString() ?? '';
    });
  }

  static final RegExp _safeArithmeticExpr = RegExp(r'^[0-9+\-*/(). \t]*$');
}
