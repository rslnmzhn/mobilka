import 'dart:convert';

import 'package:xml/xml.dart' show XmlDefaultEntityMapping;
import 'package:xml/xml_events.dart';

import '../domain/document_limits.dart';
import 'bounded_ooxml_package.dart';

const wordNamespace =
    'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const sheetNamespace =
    'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const relationshipNamespace =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const packageRelationshipNamespace =
    'http://schemas.openxmlformats.org/package/2006/relationships';
const contentTypeNamespace =
    'http://schemas.openxmlformats.org/package/2006/content-types';

final class DocumentXmlNode {
  DocumentXmlNode(this.namespace, this.name, this.attributes);
  final String namespace;
  final String name;
  final Map<String, String> attributes;
  final List<Object> content = [];
  Iterable<DocumentXmlNode> get children =>
      content.whereType<DocumentXmlNode>();
  String? attribute(String name, {String namespace = ''}) =>
      attributes['{$namespace}$name'];
  bool isName(String ns, String local) => namespace == ns && name == local;
  String get text => content
      .map((item) => item is DocumentXmlNode ? item.text : item as String)
      .join();
}

final class BoundedDocumentXml {
  BoundedDocumentXml(this.limits);
  final DocumentLimits limits;
  int _events = 0;

  DocumentXmlNode parse(List<int> bytes) {
    if (bytes.length > limits.memberBytes) {
      throw const DocumentException('document_xml_limit');
    }
    try {
      var source = utf8.decode(bytes, allowMalformed: false);
      if (source.startsWith('\ufeff')) source = source.substring(1);
      final declarations = RegExp(
        r'<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<!DOCTYPE|<!ENTITY',
      );
      if (declarations
              .allMatches(source)
              .any(
                (match) => match[0] == '<!DOCTYPE' || match[0] == '<!ENTITY',
              ) ||
          source.contains('\u0000')) {
        throw const DocumentException('unsafe_document_xml');
      }
      final encoding = RegExp(
        r'''^<\?xml\s[^?]*encoding\s*=\s*["']([^"']+)["']''',
      ).firstMatch(source)?.group(1);
      if (encoding != null && encoding.toLowerCase() != 'utf-8') {
        throw const DocumentException('unsupported_document_encoding');
      }
      final stack = <DocumentXmlNode>[];
      final scopes = <Map<String, String>>[];
      DocumentXmlNode? root;
      for (final event in parseEvents(
        source,
        entityMapping: const _StrictEntities(),
        validateNesting: true,
        validateDocument: true,
      )) {
        if (++_events > limits.xmlEvents) {
          throw const DocumentException('document_xml_limit');
        }
        if (event is XmlDoctypeEvent || event is XmlProcessingEvent) {
          throw const DocumentException('unsafe_document_xml');
        }
        if (event is XmlStartElementEvent) {
          if (stack.length >= limits.xmlDepth ||
              event.attributes.length > limits.xmlAttributes) {
            throw const DocumentException('document_xml_limit');
          }
          final scope = <String, String>{
            'xml': 'http://www.w3.org/XML/1998/namespace',
            if (scopes.isNotEmpty) ...scopes.last,
          };
          final rawNames = <String>{};
          for (final attribute in event.attributes) {
            if (!rawNames.add(attribute.name)) _invalid();
            if (attribute.name == 'xmlns') {
              scope[''] = attribute.value;
            } else if (attribute.name.startsWith('xmlns:')) {
              final prefix = attribute.name.substring(6);
              if (prefix == 'xmlns' ||
                  prefix.isEmpty ||
                  (prefix == 'xml' && attribute.value != scope['xml'])) {
                _invalid();
              }
              scope[prefix] = attribute.value;
            }
          }
          (String, String) expand(String name, bool attribute) {
            final pieces = name.split(':');
            if (pieces.length == 1) {
              return (attribute ? '' : scope[''] ?? '', name);
            }
            if (pieces.length != 2 ||
                pieces.any((p) => p.isEmpty) ||
                scope[pieces.first] == null ||
                scope[pieces.first]!.isEmpty) {
              _invalid();
            }
            return (scope[pieces.first]!, pieces.last);
          }

          final attributes = <String, String>{};
          for (final attribute in event.attributes) {
            if (attribute.name == 'xmlns' ||
                attribute.name.startsWith('xmlns:')) {
              continue;
            }
            final expanded = expand(attribute.name, true);
            final key = '{${expanded.$1}}${expanded.$2}';
            if (attributes.containsKey(key)) _invalid();
            attributes[key] = attribute.value;
          }
          final expanded = expand(event.name, false);
          final node = DocumentXmlNode(expanded.$1, expanded.$2, attributes);
          if (stack.isEmpty) {
            if (root != null) _invalid();
            root = node;
          } else {
            stack.last.content.add(node);
          }
          if (!event.isSelfClosing) {
            stack.add(node);
            scopes.add(scope);
          }
        } else if (event is XmlEndElementEvent) {
          stack.removeLast();
          scopes.removeLast();
        } else if (event is XmlTextEvent) {
          if (stack.isNotEmpty) stack.last.content.add(event.value);
        } else if (event is XmlCDATAEvent) {
          if (stack.isNotEmpty) stack.last.content.add(event.value);
        }
      }
      if (root == null || stack.isNotEmpty) _invalid();
      return root;
    } on DocumentException {
      rethrow;
    } on Object {
      throw const DocumentException('invalid_document_xml');
    }
  }

  static Never _invalid() =>
      throw const DocumentException('invalid_document_xml');
}

final class DocumentRelationship {
  const DocumentRelationship(this.type, this.target);
  final String type;
  final String? target;
}

final class DocumentPackageXml {
  DocumentPackageXml(BoundedOoxmlPackage package, DocumentLimits limits) {
    final parser = BoundedDocumentXml(limits);
    for (final entry in package.parts.entries) {
      parts[entry.key] = parser.parse(entry.value);
    }
    final types = require('[Content_Types].xml');
    if (!types.isName(contentTypeNamespace, 'Types')) _invalid();
    for (final node in types.children) {
      final type = node.attribute('ContentType') ?? '';
      if (type.toLowerCase().contains('macroenabled') ||
          type.toLowerCase().contains('vbaproject') ||
          type.toLowerCase().contains('oleobject')) {
        throw const DocumentException('unsupported_document_active_content');
      }
      if (node.isName(contentTypeNamespace, 'Override')) {
        final name = node.attribute('PartName');
        if (name == null ||
            !name.startsWith('/') ||
            contentTypes.containsKey(name.substring(1))) {
          _invalid();
        }
        contentTypes[name.substring(1)] = type;
      }
    }
  }

  final Map<String, DocumentXmlNode> parts = {};
  final Map<String, String> contentTypes = {};
  DocumentXmlNode require(String part) =>
      parts[part] ?? (throw const DocumentException('missing_document_part'));

  Map<String, DocumentRelationship> relationships(
    String source,
    Set<String> warnings,
  ) {
    final slash = source.lastIndexOf('/');
    final directory = slash < 0 ? '' : source.substring(0, slash + 1);
    final name = source.substring(slash + 1);
    final root =
        parts[source.isEmpty ? '_rels/.rels' : '${directory}_rels/$name.rels'];
    if (root == null) return {};
    if (!root.isName(packageRelationshipNamespace, 'Relationships')) _invalid();
    final result = <String, DocumentRelationship>{};
    for (final node in root.children) {
      if (!node.isName(packageRelationshipNamespace, 'Relationship')) {
        _invalid();
      }
      final id = node.attribute('Id');
      final type = node.attribute('Type');
      final target = node.attribute('Target');
      final mode = node.attribute('TargetMode');
      if (id == null ||
          id.isEmpty ||
          type == null ||
          target == null ||
          result.containsKey(id)) {
        _invalid();
      }
      if (mode == 'External') {
        warnings.add('external_resources_skipped');
        result[id] = DocumentRelationship(type, null);
      } else {
        if (mode != null && mode != 'Internal') _invalid();
        result[id] = DocumentRelationship(type, _resolve(directory, target));
      }
    }
    return result;
  }

  String mainPart(String expectedContentType, Set<String> warnings) {
    final candidates = relationships('', warnings).values
        .where((r) => r.type == '$relationshipNamespace/officeDocument')
        .toList();
    if (candidates.length != 1 || candidates.single.target == null) _invalid();
    final target = candidates.single.target!;
    if (contentTypes[target] != expectedContentType) {
      throw const DocumentException('unsupported_document_type');
    }
    return target;
  }

  static String _resolve(String directory, String target) {
    if (target.isEmpty ||
        target.contains('\\') ||
        target.contains(':') ||
        target.contains('%') ||
        target.contains('?') ||
        target.contains('#') ||
        target.runes.any((r) => r < 32 || r == 127)) {
      _invalid();
    }
    final segments = <String>[];
    final path = target.startsWith('/')
        ? target.substring(1)
        : '$directory$target';
    for (final segment in path.split('/')) {
      if (segment == '.') continue;
      if (segment == '..') {
        if (segments.isEmpty) _invalid();
        segments.removeLast();
      } else {
        if (segment.isEmpty || segment.endsWith(' ') || segment.endsWith('.')) {
          _invalid();
        }
        segments.add(segment);
      }
    }
    if (segments.isEmpty) _invalid();
    return segments.join('/');
  }

  static Never _invalid() =>
      throw const DocumentException('invalid_document_package');
}

final class _StrictEntities extends XmlDefaultEntityMapping {
  const _StrictEntities() : super.xml();

  @override
  String decode(String input) {
    var at = input.indexOf('&');
    while (at >= 0) {
      final end = input.indexOf(';', at + 1);
      if (end < 0) throw const DocumentException('unsafe_document_xml');
      final entity = input.substring(at + 1, end);
      if (!const {'amp', 'lt', 'gt', 'quot', 'apos'}.contains(entity)) {
        final hex = entity.startsWith('#x');
        final digits = entity.startsWith('#')
            ? entity.substring(hex ? 2 : 1)
            : '';
        if (digits.isEmpty ||
            !(hex ? RegExp(r'^[0-9a-fA-F]+$') : RegExp(r'^[0-9]+$')).hasMatch(
              digits,
            )) {
          throw const DocumentException('unsafe_document_xml');
        }
        final rune = int.tryParse(digits, radix: hex ? 16 : 10);
        if (rune == null ||
            !(rune == 9 ||
                rune == 10 ||
                rune == 13 ||
                (rune >= 32 && rune <= 0xd7ff) ||
                (rune >= 0xe000 && rune <= 0xfffd) ||
                (rune >= 0x10000 && rune <= 0x10ffff))) {
          throw const DocumentException('unsafe_document_xml');
        }
      }
      at = input.indexOf('&', end + 1);
    }
    return super.decode(input);
  }
}
