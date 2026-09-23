import 'dart:async';

import 'package:logging/logging.dart';

import '../../data_sources/model/data_source.dart';
import '../model/embedding_template.dart';
import '../model/template.dart';
import 'template_expression_evaluator.dart';

/// Result of rendering a template
class TemplateRenderResult {
  final Map<String, String> renderedDocuments;
  final List<String> errors;

  const TemplateRenderResult({
    required this.renderedDocuments,
    required this.errors,
  });

  bool get hasErrors => errors.isNotEmpty;
  int get successCount => renderedDocuments.length;
  int get errorCount => errors.length;
}

/// Service for processing embedding templates with data source fields
class TemplateRenderer {
  static final Logger _logger = Logger('TemplateRenderer');

  final DataSource _dataSource;
  final EmbeddingTemplate _template;

  TemplateRenderer({
    required DataSource dataSource,
    required EmbeddingTemplate template,
  }) : _dataSource = dataSource,
       _template = template;

  /// Render a template with data from a data source
  Future<TemplateRenderResult> renderTemplate({
    int? limit,
    int offset = 0,
  }) async {
    _logger.info(
      'Rendering template: ${_template.name} with data source: ${_dataSource.name}',
    );

    // Get data from source
    final data = await _dataSource.getAllData(offset: offset, limit: limit);
    _logger.info('Retrieved ${data.length} rows from data source');

    // Render template for each row
    final renderedTexts = <String, String>{};
    final errors = <String>[];

    for (int i = 0; i < data.length; i++) {
      final documentId = Template(_template.idTemplate).render(data[i]);
      var document = Template(_template.template).render(data[i]);
      document = evaluateTemplateComputedFields(document, data[i]);
      if (documentId.isEmpty || document.isEmpty) {
        errors.add('Row $i: Rendered document or ID is empty');
        continue;
      }
      renderedTexts[documentId] = document;
    }

    _logger.info(
      'Rendered ${renderedTexts.length} texts, ${errors.length} errors',
    );

    return TemplateRenderResult(
      renderedDocuments: renderedTexts,
      errors: errors,
    );
  }

  /// Same rendering pipeline as [renderTemplate], but any `{{=expr}}`
  /// computed-field markers are resolved through
  /// [evaluateTemplateComputedFieldsSafe] instead -- used by preview flows
  /// that want the extra safety margin, even though [renderTemplate] is
  /// what a live job actually runs.
  Future<TemplateRenderResult> renderTemplateSafe({
    int? limit,
    int offset = 0,
  }) async {
    _logger.info(
      'Rendering template (safe): ${_template.name} with data source: ${_dataSource.name}',
    );

    final data = await _dataSource.getAllData(offset: offset, limit: limit);
    _logger.info('Retrieved ${data.length} rows from data source');

    final renderedTexts = <String, String>{};
    final errors = <String>[];

    for (int i = 0; i < data.length; i++) {
      final documentId = Template(_template.idTemplate).render(data[i]);
      var document = Template(_template.template).render(data[i]);
      document = evaluateTemplateComputedFieldsSafe(document, data[i]);
      if (documentId.isEmpty || document.isEmpty) {
        errors.add('Row $i: Rendered document or ID is empty');
        continue;
      }
      renderedTexts[documentId] = document;
    }

    _logger.info(
      'Rendered ${renderedTexts.length} texts, ${errors.length} errors',
    );

    return TemplateRenderResult(
      renderedDocuments: renderedTexts,
      errors: errors,
    );
  }
}
