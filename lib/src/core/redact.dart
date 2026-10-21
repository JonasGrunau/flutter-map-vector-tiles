/// Query parameters that carry credentials in style, TileJSON and tile
/// URLs: `key` (MapTiler, Protomaps), `apikey` (Thunderforest), `api_key`
/// (Stadia), `access_token` (Mapbox) and `token` (ArcGIS).
///
/// Anchored on `?` or `&`, so a parameter that merely ends in one of these
/// names (`monkey=1`) is left alone. The value runs to the next `&`, `#`,
/// whitespace or `)`, so a URL inside a message (`failed: <url> (boom)`,
/// an `http.ClientException`'s `uri=<url>`) keeps the text after it.
final _credentialParam = RegExp(
  r'([?&](?:key|apikey|api_key|access_token|token)=)[^&#\s)]+',
  caseSensitive: false,
);

/// Replaces the value of every credential query parameter in [text] with
/// `***`, keeping the parameter's name and everything around it.
///
/// [text] may be a bare URL or a whole message with URLs in it. `Logger`
/// applies it to every message; exception messages built from a URL apply
/// it themselves.
String redactKeys(String text) =>
    text.replaceAllMapped(_credentialParam, (m) => '${m[1]}***');
