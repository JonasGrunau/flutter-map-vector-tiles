import 'package:meta/meta.dart';

/// One run of attribution text, carrying the link it sat inside — if any.
@immutable
class AttributionSpan {
  /// The visible text, with markup stripped and entities decoded.
  final String text;

  /// The `href` of the `<a>` this run came from, `null` for plain text.
  final String? url;

  const AttributionSpan(this.text, {this.url});

  @override
  bool operator ==(Object other) =>
      other is AttributionSpan && other.text == text && other.url == url;

  @override
  int get hashCode => Object.hash(text, url);

  @override
  String toString() => url == null ? '"$text"' : '"$text" -> $url';
}

/// Attribution declared by a style source, or by the TileJSON it points
/// at.
///
/// Style attribution is HTML by convention — MapLibre renders it into the
/// DOM — so it arrives as a string like
/// `© <a href="https://openstreetmap.org">OpenStreetMap</a> contributors`.
/// Flutter has no DOM, so this exposes both the flattened [text] for a
/// plain `Text` widget and the [spans] if you want the links to be
/// tappable.
///
/// Most providers' terms of use require showing this on the map.
@immutable
class StyleAttribution {
  /// The value exactly as the style declared it, markup included.
  final String html;

  /// [html] with tags stripped, entities decoded and whitespace
  /// collapsed.
  final String text;

  /// [html] split into runs in document order; those inside an `<a>`
  /// carry its [AttributionSpan.url].
  final List<AttributionSpan> spans;

  const StyleAttribution({
    required this.html,
    required this.text,
    required this.spans,
  });

  /// Parses a style/TileJSON `attribution` value.
  ///
  /// Deliberately forgiving, like the rest of the style reader: anything
  /// it cannot make sense of ends up as plain text rather than throwing.
  factory StyleAttribution.parse(String html) {
    final spans = <AttributionSpan>[];
    var index = 0;

    void addPlain(String raw) {
      final text = _clean(raw);
      if (text.isNotEmpty) spans.add(AttributionSpan(text));
    }

    for (final match in _anchor.allMatches(html)) {
      addPlain(html.substring(index, match.start));
      final label = _clean(match.group(4) ?? '');
      final href = match.group(1) ?? match.group(2) ?? match.group(3) ?? '';
      if (label.isNotEmpty) {
        spans.add(AttributionSpan(label,
            url: href.isEmpty ? null : _decode(href.trim())));
      }
      index = match.end;
    }
    addPlain(html.substring(index));

    // Join with a space, but never in front of punctuation the source
    // wrote tight against the link ("OpenStreetMap contributors," vs
    // "OpenStreetMap contributors ,").
    final buffer = StringBuffer();
    for (final span in spans) {
      if (buffer.isNotEmpty && !_punctuation.hasMatch(span.text[0])) {
        buffer.write(' ');
      }
      buffer.write(span.text);
    }

    return StyleAttribution(
      html: html,
      text: buffer.toString(),
      spans: List.unmodifiable(spans),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StyleAttribution && other.html == html;

  @override
  int get hashCode => html.hashCode;

  @override
  String toString() => text;
}

final _anchor = RegExp(
  r'''<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a\s*>''',
  caseSensitive: false,
  dotAll: true,
);

final _tag = RegExp(r'<[^>]*>');
final _whitespace = RegExp(r'\s+');
final _punctuation = RegExp(r'[,.;:!?)\]]');

String _clean(String raw) =>
    _decode(raw.replaceAll(_tag, ' ')).replaceAll(_whitespace, ' ').trim();

/// The handful of entities that show up in real attribution strings.
String _decode(String raw) => raw
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&copy;', '©')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    // Last: an escaped ampersand must not re-form another entity.
    .replaceAll('&amp;', '&');
