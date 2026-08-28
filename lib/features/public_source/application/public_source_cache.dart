import 'dart:collection';
import 'dart:convert';

import '../data/public_source_transport.dart';
import 'public_source_policy.dart';

class PublicSourceCacheEntry {
  const PublicSourceCacheEntry({
    required this.finalUrl,
    required this.mime,
    required this.charset,
    required this.body,
  });

  final String finalUrl;
  final String mime;
  final String charset;
  final List<int> body;
}

class PublicSourceScopedCache {
  static const maxAliases = 64;
  static const maxAliasesPerResource = 8;
  static const maxResources = 16;

  final LinkedHashMap<PublicSourceCacheEntry, Set<String>> _resources =
      LinkedHashMap.identity();
  final Map<String, PublicSourceCacheEntry> _aliases = {};
  int _bytes = 0;

  PublicSourceCacheEntry? lookup(String alias) {
    final source = _aliases[alias];
    if (source == null) return null;
    final aliases = _resources.remove(source)!;
    _resources[source] = aliases;
    return source;
  }

  void store(PublicSourceCacheEntry source, List<String> aliases) {
    _resources[source] = aliases.toSet();
    _bytes += source.body.length;
    aliasAll(aliases, source);
    while (_resources.length > maxResources ||
        _bytes > publicSourceTransferLimit) {
      _evictOldest();
    }
  }

  void aliasAll(Iterable<String> aliases, PublicSourceCacheEntry source) {
    final owned = _resources[source]!;
    for (final alias in aliases) {
      _validateAlias(alias, owned);
      while (!_aliases.containsKey(alias) && _aliases.length >= maxAliases) {
        _evictOldest();
      }
      _aliases[alias] = source;
      owned.add(alias);
    }
  }

  void _validateAlias(String alias, Set<String> owned) {
    if (utf8.encode(alias).length > PublicSourcePolicy.maxCanonicalUrlBytes) {
      throw const PublicSourceFailure('invalid_url');
    }
    if (!owned.contains(alias) && owned.length >= maxAliasesPerResource) {
      throw const PublicSourceFailure('too_many_aliases');
    }
  }

  void _evictOldest() {
    if (_resources.isEmpty) return;
    final source = _resources.keys.first;
    final aliases = _resources.remove(source) ?? const {};
    for (final alias in aliases) {
      if (identical(_aliases[alias], source)) _aliases.remove(alias);
    }
    _bytes -= source.body.length;
  }
}
