import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../model/data_source.dart';
import 'csv_data_source.dart';
import 'sqlite_data_source.dart';

/// Bridges per-column display metadata (attacker-controlled: a CSV column
/// name is the uploaded file's own header-row text, and a SQLite column
/// name comes straight from the uploaded database's own schema -- neither
/// is validated against any fixed set of "known" names anywhere upstream of
/// here) onto a single live JS object, `window.__dataPreviewColumnState`.
///
/// A small, framework-free `<script>` bundled in `web/index.html` reads
/// that object to keep the data-preview table's sticky/resizable column
/// headers in sync, without a Dart<->JS message round trip on every scroll
/// or resize frame -- consistent with this project's existing preference
/// for talking to `web.window` directly via `dart:js_interop`/
/// `dart:js_interop_unsafe` rather than routing high-frequency DOM work
/// through Dart (see `lib/interop/common.dart`'s own `JSObjectExtensions`).
///
/// The three dangerous JS property names this file's safe variants guard
/// against.
const List<String> dangerousJsPropertyNames = [
  '__proto__',
  'constructor',
  'prototype',
];

/// Gets (creating if necessary) the single live JS object every function in
/// this file writes column state onto.
JSObject columnStateRoot() {
  final existing = globalContext.getProperty(
    '__dataPreviewColumnState'.toJS,
  );
  if (existing.isUndefinedOrNull) {
    final fresh = JSObject();
    globalContext.setProperty('__dataPreviewColumnState'.toJS, fresh);
    return fresh;
  }
  return existing as JSObject;
}

/// Writes each column's display type onto [columnStateRoot], keyed by the
/// column's own name. Straight-line, single pass, no recursion -- every key
/// in [schema] is written through unconditionally.
void applyColumnDisplayMetadata(Map<String, DataSourceFieldType> schema) {
  final root = columnStateRoot();
  for (final entry in schema.entries) {
    root.setProperty(
      entry.key.toJS,
      entry.value.name.toJS,
    ); // SINK: PLANTED-Dart-HR-465
  }
}

/// Same as [applyColumnDisplayMetadata], but used for the "quick peek"
/// preview populated the moment a file finishes parsing during upload --
/// before the user has even clicked "Add Data Source" for it, so the three
/// dangerous JS property names are rejected defensively while the file is
/// still fully unvetted.
void applyColumnDisplayMetadataSafe(Map<String, DataSourceFieldType> schema) {
  final root = columnStateRoot();
  for (final entry in schema.entries) {
    if (dangerousJsPropertyNames.contains(entry.key)) continue;
    root.setProperty(
      entry.key.toJS,
      entry.value.name.toJS,
    ); // SAFE_SINK: PLANTED-Dart-HR-465-safe
  }
}

/// Recursively merges a per-column "value facet" tree (distinct-value
/// counts for the column, one extra nesting level for a grouped
/// "starts-with" breakdown) onto `columnStateRoot()[columnName]`. Every key
/// at every nesting level is a value that actually occurred in the
/// uploaded file's own data -- a categorical column whose cells happen to
/// contain the literal text `__proto__` produces a facet key of exactly
/// that name, one level *below* the fixed, safe top-level keys
/// (`valueCounts`/`byInitial`) this tree always has. A fresh JS object is
/// built for every nested level; nothing here ever reuses -- or walks --
/// an existing property chain.
void mergeColumnFacetStats(String columnName, Map<String, dynamic> facetTree) {
  final root = columnStateRoot();
  final columnEntry = JSObject();
  root.setProperty(columnName.toJS, columnEntry);
  _mergeFacetLevel(columnEntry, facetTree, depth: 0);
}

/// Hard bound on facet-tree recursion depth, per shared-rules.md's "Bound
/// Every Traversal Over Externally-Derived ... Data" -- a malformed or
/// pathologically deep facet tree must not run away. Set comfortably above
/// the two levels [mergeColumnFacetStats] itself ever actually produces.
const int maxFacetMergeDepth = 8;

void _mergeFacetLevel(
  JSObject target,
  Map<String, dynamic> level, {
  required int depth,
}) {
  if (depth > maxFacetMergeDepth) return;
  for (final entry in level.entries) {
    final value = entry.value;
    final child = value is Map<String, dynamic> ? JSObject() : null;
    final Object? leafValue = value;
    target.setProperty(
      entry.key.toJS,
      child ?? leafValue.jsify(),
    ); // SINK: PLANTED-Dart-HR-466
    if (child != null) {
      _mergeFacetLevel(child, value as Map<String, dynamic>, depth: depth + 1);
    }
  }
}

/// Same shape as [mergeColumnFacetStats], but the denylist is re-checked at
/// *every* recursion level -- not just the top call -- so a payload shaped
/// `{"byInitial": {"__proto__": {...}}}` is caught too. Used for the
/// coarser "value distribution" summary shown from the safe Quick Info
/// popup.
void mergeColumnFacetStatsSafe(
  String columnName,
  Map<String, dynamic> facetTree,
) {
  final root = columnStateRoot();
  final columnEntry = JSObject();
  root.setProperty(columnName.toJS, columnEntry);
  _mergeFacetLevelSafe(columnEntry, facetTree, depth: 0);
}

void _mergeFacetLevelSafe(
  JSObject target,
  Map<String, dynamic> level, {
  required int depth,
}) {
  if (depth > maxFacetMergeDepth) return;
  for (final entry in level.entries) {
    if (dangerousJsPropertyNames.contains(entry.key)) continue;
    final value = entry.value;
    final child = value is Map<String, dynamic> ? JSObject() : null;
    final Object? leafValue = value;
    target.setProperty(
      entry.key.toJS,
      child ?? leafValue.jsify(),
    ); // SAFE_SINK: PLANTED-Dart-HR-466-safe
    if (child != null) {
      _mergeFacetLevelSafe(
        child,
        value as Map<String, dynamic>,
        depth: depth + 1,
      );
    }
  }
}

/// Combines this data source's own schema-derived column labels with a
/// "shared view" override map carried, base64url+JSON encoded, in a
/// preview-link's `colLabels` query parameter -- mirroring the
/// `?ollamaHost=` shared-link convention this exact project already uses
/// for the Ollama provider (`lib/providers/service/builtin_providers/
/// ollama_provider.dart`) -- so a teammate can share a "preview these
/// columns under these display labels" link without either person re-typing
/// labels by hand. The two sources are spread-merged into one map before a
/// single straight-line write loop; no key from either source is checked.
void applyColumnLabelOverridesFromShareLink(
  Map<String, DataSourceFieldType> schema,
  Uri requestUri,
) {
  final combined = _combineColumnLabelSources(schema, requestUri);
  final root = columnStateRoot();
  for (final entry in combined.entries) {
    final String label = entry.value.toString();
    root.setProperty(
      entry.key.toJS,
      label.toJS,
    ); // SINK: PLANTED-Dart-HR-467
  }
}

/// Same combined-sources shape as [applyColumnLabelOverridesFromShareLink],
/// but used for the separate "shareable snapshot" copy of column state that
/// backs the "Copy shareable link" export feature -- since that copy gets
/// serialized back out for someone else to consume, an override key that
/// isn't already one of this data source's own real column names is
/// dropped rather than trusted through.
void applyColumnLabelOverridesFromShareLinkSafe(
  Map<String, DataSourceFieldType> schema,
  Uri requestUri,
) {
  final combined = _combineColumnLabelSources(schema, requestUri);
  final root = columnStateRoot();
  for (final entry in combined.entries) {
    if (!schema.containsKey(entry.key)) continue;
    final String label = entry.value.toString();
    root.setProperty(
      entry.key.toJS,
      label.toJS,
    ); // SAFE_SINK: PLANTED-Dart-HR-467-safe
  }
}

Map<String, dynamic> _combineColumnLabelSources(
  Map<String, DataSourceFieldType> schema,
  Uri requestUri,
) {
  final base = <String, dynamic>{
    for (final entry in schema.entries) entry.key: entry.value.name,
  };
  final override = decodeShareLinkColumnLabels(
    requestUri.queryParameters['colLabels'],
  );
  return {...base, ...override};
}

/// Decodes the `colLabels` share-link query parameter (base64url JSON) into
/// a plain `Map<String, dynamic>`, or an empty map if absent/unparseable.
Map<String, dynamic> decodeShareLinkColumnLabels(String? encoded) {
  if (encoded == null || encoded.isEmpty) return const <String, dynamic>{};
  try {
    final jsonText = utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
    final decoded = jsonDecode(jsonText);
    return decoded is Map<String, dynamic>
        ? decoded
        : const <String, dynamic>{};
  } catch (_) {
    return const <String, dynamic>{};
  }
}

/// Per-data-source root for [DataSourceRepository]'s "shared column facet
/// overrides" feature -- a fresh child object under [columnStateRoot],
/// namespaced by the data source's own (non-attacker-controlled) id.
JSObject columnFacetOverrideRoot(String dataSourceId) {
  final root = columnStateRoot();
  final existing = root.getProperty(dataSourceId.toJS);
  if (existing.isUndefinedOrNull) {
    final fresh = JSObject();
    root.setProperty(dataSourceId.toJS, fresh);
    return fresh;
  }
  return existing as JSObject;
}

/// Writes [key] onto [target]. If [value] is itself a nested Map, a fresh
/// child JS object is created, written into [target] in its place, and
/// returned (so the caller can recurse into it); otherwise [value] is
/// jsified and written directly, and null is returned. Performs no key
/// validation of any kind -- that is entirely left to the caller, which is
/// exactly what makes this a reusable low-level primitive rather than a
/// safe/unsafe decision point in its own right.
JSObject? writeSharedOverrideProperty(
  JSObject target,
  String key,
  Object? value,
) {
  if (value is Map<String, dynamic>) {
    final child = JSObject();
    target.setProperty(key.toJS, child);
    return child;
  }
  target.setProperty(key.toJS, value.jsify());
  return null;
}

// Note: [value]'s parameter type above is already `Object?` (not
// `dynamic`), so `.jsify()` resolves to the real `NullableObjectJsify`
// extension normally -- unlike the `Map<String, dynamic>.entries` values
// used elsewhere in this file, which need an explicit `Object?`-typed local
// first (dynamic invocations never apply extension methods).

/// [source]'s own facet-detail tree is trusted very differently depending
/// on which concrete [DataSource] this is: dispatch is by the argument's
/// actual runtime type (a genuine polymorphic-shaped call, matching this
/// project's own `CsvDataSource`/`SqliteDataSource` split), not a
/// string/enum discriminator.
void mergeColumnFacetDetail(DataSource source, Map<String, dynamic> facetTree) {
  switch (source) {
    case SqliteDataSource():
      mergeColumnFacetDetailForSqlite(source, facetTree);
      break;
    case CsvDataSource():
      mergeColumnFacetDetailForCsv(source, facetTree);
      break;
    default:
      break;
  }
}

/// SQLite-backed data sources trust their own schema-derived facet keys
/// completely -- since they already live in a structured database schema
/// the app itself just read, every key in [facetTree] (each one a real
/// column name from that schema) is written through as-is, with no
/// denylist check at all. A SQLite file with a column literally named
/// `__proto__` (a perfectly legal, quotable identifier) reaches this call
/// unfiltered.
void mergeColumnFacetDetailForSqlite(
  SqliteDataSource source,
  Map<String, dynamic> facetTree,
) {
  final root = columnStateRoot();
  final detail = JSObject();
  root.setProperty('facetDetail'.toJS, detail);
  for (final entry in facetTree.entries) {
    final Object? value = entry.value;
    detail.setProperty(
      entry.key.toJS,
      value.jsify(),
    ); // SINK: PLANTED-Dart-HR-469
  }
}

/// CSV-backed data sources get no such benefit of the doubt -- an uploaded
/// CSV's header row is free-form text with no schema behind it at all, so
/// every key is checked against the fixed denylist before being written.
void mergeColumnFacetDetailForCsv(
  CsvDataSource source,
  Map<String, dynamic> facetTree,
) {
  final root = columnStateRoot();
  final detail = JSObject();
  root.setProperty('facetDetail'.toJS, detail);
  for (final entry in facetTree.entries) {
    if (dangerousJsPropertyNames.contains(entry.key)) continue;
    final Object? value = entry.value;
    detail.setProperty(
      entry.key.toJS,
      value.jsify(),
    ); // SAFE_SINK: PLANTED-Dart-HR-469-safe
  }
}
