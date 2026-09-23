import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Strategy for building a computed-field expression (the `{{=expr}}`
/// syntax also used by [Template.renderComputed]) ready to hand to a
/// JavaScript evaluator. Two real implementations exist below; which one a
/// caller constructs is the only thing that decides whether
/// attacker-influenceable row content can ever reach the evaluator.
abstract interface class ComputedFieldResolver {
  String buildExpression(String expression, Map<String, Object?> row);
}

/// Substitutes raw row values straight into the expression -- whatever a
/// row's own content happens to contain becomes part of the string the
/// evaluator later receives.
class JsEvalComputedFieldResolver implements ComputedFieldResolver {
  const JsEvalComputedFieldResolver();

  @override
  String buildExpression(String expression, Map<String, Object?> row) {
    var expr = expression;
    for (final entry in row.entries) {
      expr = expr.replaceAll(entry.key, entry.value?.toString() ?? '');
    }
    return expr;
  }
}

/// Substitutes only row values that parse as a number -- anything else is
/// left out entirely, so the returned expression can never carry
/// attacker-influenced, non-numeric text.
class SafeArithmeticComputedFieldResolver implements ComputedFieldResolver {
  const SafeArithmeticComputedFieldResolver();

  @override
  String buildExpression(String expression, Map<String, Object?> row) {
    var expr = expression;
    for (final entry in row.entries) {
      final numeric = num.tryParse(entry.value?.toString() ?? '');
      if (numeric == null) {
        continue;
      }
      expr = expr.replaceAll(entry.key, numeric.toString());
    }
    return expr;
  }
}

/// Resolves and evaluates a computed-field expression via [resolver] --
/// the shared dispatch point reached with a [JsEvalComputedFieldResolver].
String resolveAndEvaluateComputedId(
  ComputedFieldResolver resolver,
  String expression,
  Map<String, Object?> row,
) {
  final expr = resolver.buildExpression(expression, row);
  final jsResult = globalContext.callMethod(
    'eval'.toJS,
    expr.toJS,
  ); // SINK: PLANTED-Dart-HR-583
  return jsResult.dartify()?.toString() ?? '';
}

/// Same dispatch shape, structurally identical to
/// [resolveAndEvaluateComputedId] -- reached with a
/// [SafeArithmeticComputedFieldResolver] instead, whose [buildExpression]
/// already guarantees every substituted value was validated as numeric,
/// so the same evaluator call can never receive attacker-influenced code.
String resolveAndEvaluateComputedIdSafe(
  ComputedFieldResolver resolver,
  String expression,
  Map<String, Object?> row,
) {
  final expr = resolver.buildExpression(expression, row);
  final jsResult = globalContext.callMethod(
    'eval'.toJS,
    expr.toJS,
  ); // SAFE_SINK: PLANTED-Dart-HR-583-safe
  return jsResult.dartify()?.toString() ?? '';
}
