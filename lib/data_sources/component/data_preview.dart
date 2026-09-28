import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:jaspr/jaspr.dart';
import 'package:logging/logging.dart';
import 'package:web/web.dart' as web;

import '../../common/ui/ui.dart';
import '../model/data_source.dart';
import '../service/column_view_state_bridge.dart';
import '../service/sqlite_data_source.dart';
import 'sql_query_editor.dart';

/// A component that displays a preview of data from a data source
///
/// Shows a table with column headers, data types, and sample rows
/// Now uses shadcn/ui components for improved styling and UX
class DataPreview extends StatefulComponent {
  final DataSource dataSource;
  final int maxRows;
  final bool showDataTypes;
  final bool showRowNumbers;
  final void Function(String message)? onError;
  final void Function(DataSource dataSource)? onDataSourceUpdated;

  const DataPreview({
    required this.dataSource,
    this.maxRows = 10,
    this.showDataTypes = true,
    this.showRowNumbers = true,
    this.onError,
    this.onDataSourceUpdated,
    super.key,
  });

  @override
  State<DataPreview> createState() => _DataPreviewState();
}

class _DataPreviewState extends State<DataPreview> {
  List<Map<String, dynamic>> _sampleData = [];
  Map<String, DataSourceFieldType> _schema = {};
  bool _isLoading = false;
  String? _error;
  int _totalRows = 0;

  /// The "quick formula" text currently typed into the formula bar, e.g.
  /// `{{price}} * {{quantity}}`, and the result of the last time it was
  /// evaluated (by either the JS-eval or the safe action).
  String _formula = '';
  String? _formulaResult;

  static final Logger _logger = Logger('DataPreview');

  /// Matches the first URL-looking token in a cell's text, so a "link"
  /// column (or any free-text column that happens to contain one) can be
  /// opened with a single click instead of copy-pasting it into the
  /// address bar. Deliberately loose -- it has no opinion on the scheme.
  static final RegExp _urlLikeToken = RegExp(r'\S+://\S+');

  /// Extracts the first URL-looking token from [value], or null if none is
  /// found. Used by both the quick "Open" button on a cell and the
  /// header's validated "Open first link" action.
  String? _extractFirstLink(String value) {
    return _urlLikeToken.firstMatch(value)?.group(0);
  }

  @override
  void initState() {
    super.initState();
    _logger.finest(
      'DataPreview initialized for data source: ${component.dataSource.name} (${component.dataSource.type})',
    );
    _loadPreviewData();
  }

  @override
  void didUpdateComponent(DataPreview oldComponent) {
    super.didUpdateComponent(oldComponent);
    // Reload data if the data source changed
    if (oldComponent.dataSource != component.dataSource) {
      _logger.info('Data source changed, reloading preview data');
      _loadPreviewData();
    }
  }

  Future<void> _loadPreviewData() async {
    _logger.info(
      'Loading preview data for: ${component.dataSource.name} (max rows: ${component.maxRows})',
    );

    setState(() {
      _isLoading = true;
      _error = null;
    });

    _logger.finest(
      'Starting parallel data loading for schema, sample data, and row count',
    );

    try {
      // Load schema and sample data in parallel
      final (schema, sampleData, totalRows) = await (
        component.dataSource.getSchema(),
        component.dataSource.getSampleData(limit: component.maxRows),
        component.dataSource.getRowCount(),
      ).wait;

      _logger.info(
        'Successfully loaded preview data: ${sampleData.length} rows, ${schema.length} columns, $totalRows total rows',
      );
      _logger.finest('Schema fields: ${schema.keys.join(', ')}');

      setState(() {
        _schema = schema;
        _sampleData = sampleData;
        _totalRows = totalRows;
        _isLoading = false;
      });

      // Keep the live column-state JS object (read by the bundled
      // sticky/resizable-header script) in sync with what just loaded.
      applyColumnDisplayMetadata(schema);

      // Apply any "shared view" column-label overrides carried in this
      // page's own URL, mirroring the `?ollamaHost=` shared-link
      // convention already used for the Ollama provider. The "live" sync
      // copy above is generously merged; a second, export-focused
      // snapshot -- the one the "Copy shareable link" feature re-shares --
      // is kept separately and validated more strictly, since it gets
      // serialized back out for someone else to consume.
      applyColumnLabelOverridesFromShareLink(schema, Uri.base);
      applyColumnLabelOverridesFromShareLinkSafe(schema, Uri.base);

      // Sync a per-column "facet detail" snapshot too. Which of the two
      // internal write paths actually runs depends entirely on the
      // concrete DataSource type this preview is showing.
      mergeColumnFacetDetail(
        component.dataSource,
        _buildFacetDetailTree(schema, sampleData),
      );
    } catch (e) {
      final errorMessage = 'Failed to load preview data: ${e.toString()}';
      _logger.severe(
        'Failed to load preview data for ${component.dataSource.name}',
        e,
      );
      setState(() {
        _error = errorMessage;
        _isLoading = false;
      });
      component.onError?.call(errorMessage);
    }
  }

  @override
  Component build(BuildContext context) {
    return div(classes: 'space-y-6', [
      // SQL Query Editor for SQLite data sources
      if (component.dataSource is SqliteDataSource)
        SqlQueryEditor(
          dataSource: component.dataSource as SqliteDataSource,
          onQueryApplied: () {
            _loadPreviewData();
            // Notify parent that the data source has been updated
            component.onDataSourceUpdated?.call(component.dataSource);
          },
        ),

      // Data Preview Card
      Card(
        className: 'data-preview',
        children: [_buildHeader(), _buildFormulaBar(), _buildContent()],
      ),
    ]);
  }

  /// A "quick formula" bar that lets a user try out a `{{field}}`-style
  /// expression against the first loaded sample row before pasting it
  /// into an embedding template's `{{=expr}}` computed field.
  Component _buildFormulaBar() {
    if (_sampleData.isEmpty) {
      return fragment([]);
    }
    return div(classes: 'px-6 pb-4 flex items-center space-x-2', [
      Input.text(
        placeholder: '{{price}} * {{quantity}}',
        value: _formula,
        onChange: (value) => setState(() => _formula = value),
      ),
      Button(
        variant: ButtonVariant.outline,
        size: ButtonSize.sm,
        onPressed: _evaluateFormula,
        children: [text('Evaluate')],
      ),
      Button(
        variant: ButtonVariant.ghost,
        size: ButtonSize.sm,
        onPressed: _evaluateFormulaSafe,
        children: [text('Evaluate (safe)')],
      ),
      if (_formulaResult case final result?)
        span(classes: 'text-sm text-neutral-600', [text('= $result')]),
    ]);
  }

  /// Opens [url] straight from whatever cell value it was extracted from,
  /// with no check at all on the scheme -- a note field or an uploaded
  /// CSV column can contain anything, including a `javascript:`/`data:`
  /// "link".
  void _openCellLink(String url) {
    web.window.open(url, '_blank'); // SINK: PLANTED-Dart-HR-446
  }

  /// Scans the currently-loaded sample rows for the first cell containing
  /// a URL-looking token and opens it, but only after confirming the
  /// scheme is actually `http`/`https` -- a `javascript:`/`data:`/`vbscript:`
  /// "link" hiding in the data is silently ignored instead of opened.
  void _openFirstLinkSafe() {
    for (final row in _sampleData) {
      for (final value in row.values) {
        if (value == null) continue;
        final url = _extractFirstLink(value.toString());
        if (url == null) continue;
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
          continue;
        }
        web.window.open(url, '_blank'); // SAFE_SINK: PLANTED-Dart-HR-446-safe
        return;
      }
    }
  }

  /// Pops the data source's own quick-info summary open in a small new
  /// window. What's actually in that summary -- and whether it's safe to
  /// stream straight into the popup with `document.write` -- depends
  /// entirely on which concrete [DataSource] implementation this is.
  void _showQuickInfo() {
    final infoWindow = web.window.open('', '_blank', 'width=400,height=200');
    infoWindow?.document.write(
      component.dataSource.buildQuickInfoHtml().toJS,
    ); // SINK: PLANTED-Dart-HR-449
    infoWindow?.document.close();
  }

  /// Same popup, but built from the always-safe plain-text summary and
  /// inserted as a text node -- the browser never parses it as markup,
  /// regardless of which [DataSource] implementation produced it.
  void _showQuickInfoSafe() {
    final infoWindow = web.window.open('', '_blank', 'width=400,height=200');
    final doc = infoWindow?.document;
    if (doc == null) return;
    final textNode = doc.createTextNode(
      component.dataSource.buildQuickInfoPlainText(),
    ); // SAFE_SINK: PLANTED-Dart-HR-449-safe
    doc.body?.appendChild(textNode);
    doc.close();
  }

  /// Evaluates the current "quick formula" against the first loaded sample
  /// row by substituting `{{field}}` references with the row's own raw
  /// value (via [DataSource.buildQuickFormulaExpression], a different
  /// file/class from this sink call) and running the result as JavaScript
  /// -- lets a user sanity-check a formula against real data before
  /// pasting it into an embedding template.
  void _evaluateFormula() {
    if (_sampleData.isEmpty) return;
    final expr = component.dataSource.buildQuickFormulaExpression(
      _formula,
      _sampleData.first,
    );
    final jsResult = globalContext.callMethod(
      'eval'.toJS,
      expr.toJS,
    ); // SINK: PLANTED-Dart-HR-582
    setState(() {
      _formulaResult = jsResult.dartify()?.toString() ?? '';
    });
  }

  /// Same quick-formula evaluation, but the substitution comes from
  /// [DataSource.buildQuickFormulaExpressionSafe] instead -- every
  /// substituted row value arrives as a properly-quoted JSON literal, so
  /// nothing in the sample data can break out of its own literal and add
  /// new JavaScript for the evaluator to run.
  void _evaluateFormulaSafe() {
    if (_sampleData.isEmpty) return;
    final expr = component.dataSource.buildQuickFormulaExpressionSafe(
      _formula,
      _sampleData.first,
    );
    final jsResult = globalContext.callMethod(
      'eval'.toJS,
      expr.toJS,
    ); // SAFE_SINK: PLANTED-Dart-HR-582-safe
    setState(() {
      _formulaResult = jsResult.dartify()?.toString() ?? '';
    });
  }

  /// Builds a `{column: mostCommonValueAsString}` tree from the currently
  /// loaded sample rows, used by [mergeColumnFacetDetail]'s per-column
  /// "facet detail" sync. Both the column names (keys) and the sampled
  /// values are drawn straight from the loaded file's own data.
  Map<String, dynamic> _buildFacetDetailTree(
    Map<String, DataSourceFieldType> schema,
    List<Map<String, dynamic>> sampleData,
  ) {
    return {
      for (final column in schema.keys)
        column: _mostCommonValue(column, sampleData) ?? '',
    };
  }

  String? _mostCommonValue(
    String column,
    List<Map<String, dynamic>> sampleData,
  ) {
    final counts = <String, int>{};
    for (final row in sampleData) {
      final raw = row[column];
      if (raw == null) continue;
      final key = raw.toString();
      counts[key] = (counts[key] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  /// Builds a nested `{valueCounts: {...}, byInitial: {...}}` facet tree
  /// for [column] from the currently loaded sample rows -- distinct values
  /// at the top, the same values grouped by their first character one
  /// level down (an extra nesting level so the popup can show a
  /// "starts-with" breakdown). Every key below the two fixed top-level
  /// names is a value that actually occurred in [column]'s own data.
  Map<String, dynamic> _computeColumnFacetTree(
    String column,
    List<Map<String, dynamic>> sampleData,
  ) {
    final valueCounts = <String, int>{};
    for (final row in sampleData) {
      final raw = row[column];
      if (raw == null) continue;
      final key = raw.toString();
      valueCounts[key] = (valueCounts[key] ?? 0) + 1;
    }
    final byInitial = <String, Map<String, dynamic>>{};
    for (final entry in valueCounts.entries) {
      final initial = entry.key.isEmpty ? '' : entry.key[0].toUpperCase();
      (byInitial[initial] ??= <String, dynamic>{})[entry.key] = entry.value;
    }
    return {'valueCounts': valueCounts, 'byInitial': byInitial};
  }

  /// Shows the detailed, per-column value-distribution facets -- built
  /// fresh from the currently loaded sample rows and merged onto the live
  /// column-state JS object so the same bundled header script that reads
  /// [applyColumnDisplayMetadata]'s output can render a facet breakdown
  /// inline under each column header.
  void _showColumnFacetDetail() {
    for (final column in _schema.keys) {
      mergeColumnFacetStats(column, _computeColumnFacetTree(column, _sampleData));
    }
  }

  /// Same facet breakdown, but via the denylist-guarded merge path -- used
  /// for the coarser summary shown from the safe (plain-text) Quick Info
  /// popup, which deliberately favors caution over completeness.
  void _showColumnFacetSummarySafe() {
    for (final column in _schema.keys) {
      mergeColumnFacetStatsSafe(
        column,
        _computeColumnFacetTree(column, _sampleData),
      );
    }
  }

  Component _buildHeader() {
    return CardHeader(
      children: [
        div(classes: 'flex items-center justify-between', [
          div(classes: 'flex items-center space-x-3', [
            h3(classes: 'text-lg font-medium text-neutral-900', [
              text('Data Preview'),
            ]),
            if (_isLoading)
              div(
                classes: 'flex items-center space-x-2 text-sm text-neutral-500',
                [
                  Skeleton(className: 'h-4 w-4 rounded-full'),
                  span([text('Loading...')]),
                ],
              )
            else if (_sampleData.isNotEmpty)
              span(classes: 'text-sm text-neutral-500', [
                text('Showing ${_sampleData.length} of $_totalRows rows'),
              ]),
          ]),
          div(classes: 'flex items-center space-x-2', [
            if (_sampleData.isNotEmpty)
              IconButton(
                className: 'text-neutral-500',
                variant: ButtonVariant.ghost,
                onPressed: _openFirstLinkSafe,
                icon: FaIcon(FaIcons.solid.search),
              ),
            IconButton(
              className: 'text-neutral-500',
              variant: ButtonVariant.ghost,
              onPressed: _showQuickInfo,
              icon: FaIcon(FaIcons.solid.fileText),
            ),
            IconButton(
              className: 'text-neutral-400',
              variant: ButtonVariant.ghost,
              onPressed: _showQuickInfoSafe,
              icon: FaIcon(FaIcons.regular.circle),
            ),
            if (_sampleData.isNotEmpty) ...[
              IconButton(
                className: 'text-neutral-500',
                variant: ButtonVariant.ghost,
                onPressed: _showColumnFacetDetail,
                icon: FaIcon(FaIcons.solid.chartBar),
              ),
              IconButton(
                className: 'text-neutral-400',
                variant: ButtonVariant.ghost,
                onPressed: _showColumnFacetSummarySafe,
                icon: FaIcon(FaIcons.regular.circleDot),
              ),
            ],
            Badge(
              variant: BadgeVariant.secondary,
              children: [text(component.dataSource.type.name.toUpperCase())],
            ),
            span(classes: 'text-sm text-neutral-500', [
              text(component.dataSource.name),
            ]),
          ]),
        ]),
      ],
    );
  }

  Component _buildContent() {
    if (_isLoading) {
      return CardContent(
        children: [
          div(classes: 'p-8 text-center space-y-4', [
            Skeleton(className: 'h-8 w-8 rounded-full mx-auto'),
            Skeleton(className: 'h-4 w-48 mx-auto'),
            div(classes: 'space-y-2', [
              Skeleton(className: 'h-4 w-full'),
              Skeleton(className: 'h-4 w-3/4'),
              Skeleton(className: 'h-4 w-5/6'),
            ]),
          ]),
        ],
      );
    }

    if (_error case final error?) {
      return CardContent(
        children: [
          Alert(
            variant: AlertVariant.destructive,
            children: [
              div(classes: 'flex', [
                div(classes: 'flex-shrink-0', [
                  svg(
                    classes: 'h-5 w-5',
                    attributes: {
                      'fill': 'currentColor',
                      'viewBox': '0 0 20 20',
                    },
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
                div(classes: 'ml-3 flex-1', [
                  AlertTitle(children: [text('Error loading preview')]),
                  AlertDescription(children: [text(error)]),
                  div(classes: 'mt-4', [
                    Button(
                      variant: ButtonVariant.outline,
                      size: ButtonSize.sm,
                      onPressed: _loadPreviewData,
                      children: [text('Retry')],
                    ),
                  ]),
                ]),
              ]),
            ],
          ),
        ],
      );
    }

    if (_sampleData.isEmpty) {
      return CardContent(
        children: [
          div(classes: 'p-8 text-center', [
            div(classes: 'text-neutral-400 mb-4', [
              svg(
                classes: 'mx-auto h-12 w-12',
                attributes: {
                  'fill': 'none',
                  'viewBox': '0 0 24 24',
                  'stroke': 'currentColor',
                },
                [
                  path(
                    attributes: {
                      'stroke-linecap': 'round',
                      'stroke-linejoin': 'round',
                      'stroke-width': '2',
                      'd':
                          'M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z',
                    },
                    [],
                  ),
                ],
              ),
            ]),
            h3(classes: 'text-sm font-medium text-neutral-900 mb-2', [
              text('No data available'),
            ]),
            p(classes: 'text-sm text-neutral-500', [
              text(
                'This data source appears to be empty or contains no accessible data.',
              ),
            ]),
          ]),
        ],
      );
    }

    return CardContent(
      children: [
        div(classes: 'overflow-x-auto', [
          table(classes: 'min-w-full divide-y divide-neutral-200', [
            _buildTableHeader(),
            _buildTableBody(),
          ]),
        ]),
      ],
    );
  }

  Component _buildTableHeader() {
    final columns = _sampleData.isNotEmpty
        ? _sampleData.first.keys.toList()
        : <String>[];

    return thead(classes: 'bg-neutral-50', [
      tr([
        if (component.showRowNumbers)
          th(
            classes:
                'px-6 py-3 text-left text-xs font-medium text-neutral-500 uppercase tracking-wider bg-neutral-100',
            [text('#')],
          ),
        for (final column in columns)
          th(
            classes:
                'px-6 py-3 text-left text-xs font-medium text-neutral-500 uppercase tracking-wider',
            [
              div(classes: 'flex flex-col space-y-2', [
                span(classes: 'font-medium text-neutral-900', [text(column)]),
                if (component.showDataTypes && _schema.containsKey(column))
                  Badge(
                    variant: BadgeVariant.outline,
                    className: 'text-xs w-fit',
                    children: [text(_getDisplayType(_schema[column]!))],
                  ),
              ]),
            ],
          ),
      ]),
    ]);
  }

  Component _buildTableBody() {
    return tbody(classes: 'bg-white divide-y divide-neutral-200', [
      for (int index = 0; index < _sampleData.length; index++)
        _buildTableRow(_sampleData[index], index),
    ]);
  }

  Component _buildTableRow(Map<String, dynamic> row, int index) {
    return tr(classes: index % 2 == 0 ? 'bg-white' : 'bg-neutral-50', [
      if (component.showRowNumbers)
        td(
          classes:
              'px-6 py-4 whitespace-nowrap text-sm font-medium text-neutral-500 bg-neutral-100',
          [text('${index + 1}')],
        ),
      for (final entry in row.entries)
        td(classes: 'px-6 py-4 whitespace-nowrap text-sm text-neutral-900', [
          _buildCellContent(entry.value, entry.key),
        ]),
    ]);
  }

  Component _buildCellContent(dynamic value, String columnName) {
    if (value == null) {
      return Badge(
        variant: BadgeVariant.outline,
        className: 'text-neutral-400 italic',
        children: [text('null')],
      );
    }

    final stringValue = value.toString();
    final fieldType = _schema[columnName];

    // Truncate long values
    final displayValue = stringValue.length > 50
        ? '${stringValue.substring(0, 47)}...'
        : stringValue;

    // Style based on data type
    final cellClasses = StringBuffer('font-mono text-sm');

    switch (fieldType) {
      case DataSourceFieldType.integer:
        cellClasses.write(' text-primary-600');
      case DataSourceFieldType.real:
        cellClasses.write(' text-green-600');
      case DataSourceFieldType.boolean:
        cellClasses.write(' text-purple-600');
      case DataSourceFieldType.date:
      case DataSourceFieldType.datetime:
        cellClasses.write(' text-indigo-600');
      default:
        cellClasses.write(' text-neutral-900');
    }

    final cellContent = span(classes: cellClasses.toString(), [
      text(displayValue),
    ]);

    // Wrap with tooltip if value is truncated
    final wrapped = stringValue.length > 50
        ? Tooltip(content: stringValue, child: cellContent)
        : cellContent;

    // Cell values routinely contain a URL when the source data has a
    // "link"/"website"/"source" column -- offer a one-click way to follow
    // it instead of making the user copy-paste it into the address bar.
    final link = fieldType == DataSourceFieldType.text
        ? _extractFirstLink(stringValue)
        : null;
    if (link == null) {
      return wrapped;
    }

    return div(classes: 'flex items-center space-x-1', [
      wrapped,
      IconButton(
        className: 'text-neutral-400',
        variant: ButtonVariant.ghost,
        onPressed: () => _openCellLink(link),
        icon: FaIcon(FaIcons.solid.share),
      ),
    ]);
  }

  String _getDisplayType(DataSourceFieldType type) {
    switch (type) {
      case DataSourceFieldType.integer:
        return 'int';
      case DataSourceFieldType.real:
        return 'number';
      case DataSourceFieldType.text:
        return 'text';
      case DataSourceFieldType.boolean:
        return 'bool';
      case DataSourceFieldType.date:
        return 'date';
      case DataSourceFieldType.datetime:
        return 'datetime';
      case DataSourceFieldType.blob:
        return 'binary';
      default:
        return type.name;
    }
  }
}
