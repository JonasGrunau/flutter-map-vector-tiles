<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# style

## Purpose

The style engine: load a MapLibre / Mapbox GL style document and everything it
references (TileJSON sources, sprite sheet + index), then compile it into a
`Theme` of paintable layers whose properties are Dart closures. Compilation
happens once at read time; nothing here re-parses JSON per frame.

## Key Files

| File | Description |
|------|-------------|
| `style_reader.dart` | `StyleReader` / `Style` — fetches the style document, resolves sources through TileJSON, substitutes `{key}`, builds `TileProviders` and `RasterTileSource`s, loads sprites, and owns stale-while-revalidate disk caching via `_Loader`. Relative URLs resolve against the declaring document (tile templates against the TileJSON URL when they came from one — the ArcGIS `"url": "../../"` shape); template braces are restored after `Uri.resolve` percent-encodes them. `pmtiles://` source URLs bypass TileJSON and open a `PmTilesVectorTileProvider`. Collects each source's `attribution` (the source's own value overriding its TileJSON's, as in MapLibre) into `Style.attributions`, deduplicated in document order. Throws `StyleReaderException`; redacts API keys in logs |
| `attribution.dart` | `StyleAttribution` / `AttributionSpan` — style attribution is HTML by convention, so `StyleAttribution.parse` flattens it to `text` for a `Text` widget *and* keeps `spans` (text + link) for tappable rendering; `html` is the untouched declaration. Regex-based and forgiving: anything it cannot parse degrades to plain text |
| `expression_parser.dart` | `ExpressionParser` — the largest file here (~950 lines). Compiles modern expression arrays *and* legacy function/filter syntax into `Expr` closures: `let`/`var`, comparisons, `case`, `match`, `step`, `interpolate` (incl. cubic-bezier easing), the full math operator set, and property references |
| `expression.dart` | The compiled-expression runtime: `typedef Expr`, `EvalContext` (feature properties + zoom + vars), coercions (`toBoolean`/`toNumber`/`toColor`/`toStringValue`), and the typed property wrappers `DoubleProp`, `ColorProp`, `StringProp`, `BoolProp`, `NumListProp`, `StringListProp` — each with a fallback and an `isConstant` fast path |
| `theme.dart` | The compiled style model: `Theme` and the sealed `ThemeLayer` hierarchy — `BackgroundThemeLayer`, `FillThemeLayer`, `LineThemeLayer`, `RasterThemeLayer`, `CircleThemeLayer`, `SymbolThemeLayer`, with `coversZoom()` and `matches()` |
| `theme_reader.dart` | `ThemeReader` — turns style JSON layers into `ThemeLayer`s, mapping every paint/layout property to a typed prop with the spec's default as fallback; handles `{token}` templates in text fields |
| `css_color.dart` | CSS colour parsing: hex, `rgb()`/`rgba()`, `hsl()`/`hsla()` and the full named-colour table |
| `sprite_atlas.dart` | `SpriteAtlas` — one decoded sheet image plus named sub-rectangles parsed from the sprite index JSON, including `sdf` and `pixelRatio` per sprite |

## For AI Agents

### Working In This Directory

- **Tolerance is a feature, not sloppiness.** Unknown layer types, unknown
  paint properties and unparseable expressions must degrade *per layer* with a
  `Logger.warn` (`_unsupported`), never throw. One exotic layer must not kill a
  user's whole map.
- **Adding a style property is a three-file change**: a typed prop on the layer
  in `theme.dart`, parsing with the spec default in `theme_reader.dart`, and
  use in `render/`. Miss the third and it parses silently and draws nothing.
- **Property references must be registered.** `ExpressionParser._refProp` /
  `_refLegacyKey` record which feature properties the theme reads; that set is
  what `pipeline/` uses to trim tiles. An expression that reads a property
  without registering it evaluates to `null` on the worker.
- **Fallbacks must match the MapLibre spec defaults**, not convenient values —
  a wrong fallback is invisible on styles that set the property and wrong on
  those that don't.
- `SpriteAtlas.dispose()` disposes the sheet image; `Style.dispose()` fans out
  to sprites and providers.

### Testing Requirements

- `test/expression_test.dart` (331 lines) — operators, interpolation, legacy
  syntax, coercions
- `test/theme_reader_test.dart` — layer parsing and defaults
- `test/css_color_test.dart` — every colour syntax
- `test/style_reader_cache_test.dart` — stale-while-revalidate behaviour
- `test/style_reader_sources_test.dart` — source URL resolution: relative
  TileJSON and tile templates (ArcGIS `root.json` shape), `{key}`
  substitution in TileJSON URLs
- `test/attribution_test.dart` — attribution parsing (links, entities,
  stray markup) and collection (source over TileJSON, dedup, order)

New expression operators need a case in `expression_test.dart` *and* an
explicit unsupported-input case proving the degradation path.

### Common Patterns

- `isConstant` on typed props lets the renderer hoist evaluation out of
  per-feature loops — set it whenever an expression compiles to a literal.
- `zoomOnly` on typed props memoizes the coerced result against
  `ctx.zoom`: the parser proves per property (via `parseForProperty`)
  that the expression reads no feature data, so a whole tile pass (one
  fixed zoom) evaluates it once. Anything that reads feature data —
  including `geometry-type`, `id` and legacy `$type`/`$id` — must set
  `_readsFeature`, or the memo returns stale values across features.
- Expressions are closures over parse-time state; they must not capture
  anything mutable or non-transferable (the zoom memo lives in the Prop
  wrappers, not in the closures).

## Dependencies

### Internal

- `logger.dart`, `cache/disk_cache.dart`, `provider/`, `tile_providers.dart`

### External

- `http`, `dart:ui` (`Color`, `Image`), `dart:convert`

<!-- MANUAL: -->
