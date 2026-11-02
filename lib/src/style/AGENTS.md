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
| `style_reader.dart` | `StyleReader` / `Style` — fetches the style document, resolves sources through TileJSON, substitutes `{key}`, builds `TileProviders` and `RasterTileSource`s (`raster` sources, and `raster-dem` ones with their `DemEncoding` — `mapbox` unless `encoding` says `terrarium` or `custom`), loads sprites, and owns stale-while-revalidate disk caching via `_Loader`. Relative URLs resolve against the declaring document (tile templates against the TileJSON URL when they came from one — the ArcGIS `"url": "../../"` shape); template braces are restored after `Uri.resolve` percent-encodes them. `pmtiles://` source URLs bypass TileJSON and open a `PmTilesVectorTileProvider`. The `resolveProvider` callback is consulted first of all, before any URL is read, so callers can substitute their own provider (a local MBTiles archive, say) for a source id — it covers vector and raster sources alike, and the resulting provider is owned by the `Style`. Collects each source's `attribution` (the source's own value overriding its TileJSON's, as in MapLibre) into `Style.attributions`, deduplicated in document order. Applies `language` through `localizeStyle` before compiling, and suffixes the theme id with it (`|language=de`) so finished tiles, which hold label text, never mix languages. Throws `StyleReaderException`, whose URLs go through `redactKeys` (its log messages are redacted by `Logger`) |
| `label_language.dart` | `localizeStyle` / `localizeTextField` — the pure JSON rewrite behind `StyleReader.language`. Wraps the smallest subexpression of a symbol layer's `text-field` that holds every value-position name reference (`name`, `name:*`, `name_*`) as `coalesce(name:<lang>, name_<lang>, original)` — inside a `concat` only the run spanning the names; under a `case`/`match`/`step`/`coalesce`/`string` each branch that shows a name on its own, unless every such branch is just a name — and folds `resolved-locale` to the language in every layer. `{token}` templates and zoom stop functions that reference a name become the equivalent `concat` / `step` first; property functions are left alone. Returns its argument itself when nothing changes. Not exported |
| `attribution.dart` | `StyleAttribution` / `AttributionSpan` — style attribution is HTML by convention, so `StyleAttribution.parse` flattens it to `text` for a `Text` widget *and* keeps `spans` (text + link) for tappable rendering; `html` is the untouched declaration. Regex-based and forgiving: anything it cannot parse degrades to plain text |
| `expression_parser.dart` | `ExpressionParser` — the largest file here (~1300 lines). Compiles every operator of the MapLibre style spec *and* legacy function/filter syntax (zoom, property and zoom-and-property functions) into `Expr` closures. Constructed with the `globalState` that `global-state` reads, compiled in as constants. Tracks `readsZoom` — sticky, set by `["zoom"]` and by legacy functions keyed on the zoom — which the reader samples after a layer's filter; `readsGlobalState` (the reader keeps the style document only then); and `readsGeometry` (`within`, `distance`) |
| `geometry_expressions.dart` | `within` and `distance`: `GeoShapes` parses the GeoJSON argument once at compile time; `featureWithin` tests in Web Mercator on the feature's own grid (MapLibre's boundary and antimeridian rules); `featureDistance` measures on a local flat approximation of the WGS84 ellipsoid around the feature's first coordinate, as MapLibre does. Brute force over segments — the parser memoizes the answer per feature (an `Expando` on its coordinate list), so a paint property pays it once per feature, not per display tile |
| `interpolation.dart` | `lerpColor` in RGB, CIE LAB (D50, Bradford-adapted sRGB) or HCL — for `interpolate-lab` / `-hcl` and a legacy function's `colorSpace` — and `cubicBezier`, an exact (1e-6) solver; Flutter's `Cubic` is off by up to 0.7% of the ramp |
| `number_format.dart` | `formatNumber` for `number-format`: `intl` for locale digits and currencies (formats cached by options, bounded), English short unit symbols; fraction digits capped at 15 significant digits, where `intl`'s 64-bit rounding overflows |
| `expression.dart` | The compiled-expression runtime: `typedef Expr`, `EvalContext` (feature properties + zoom + vars), the `@internal` `GeometryEvalContext` subclass carrying the `FeatureGeometry` that `within`/`distance` read, and `featureContext`, which builds the subclass only when a geometry is given — keep the geometry off `EvalContext` itself: one is allocated per feature evaluated, and the extra field slowed fresh-tile filter matching on the phone; coercions (`toBoolean`/`toNumber`/`toColor`/`toStringValue`; `toStringValue` writes arrays and objects as JSON), and the typed property wrappers `DoubleProp`, `ColorProp`, `StringProp`, `BoolProp`, `NumListProp`, `StringListProp` — each with a fallback and an `isConstant` fast path |
| `theme.dart` | The compiled style model: `Theme` — with `globalState` and `withGlobalState`, which asks the theme's `GlobalStateFamily` (`@internal`, hidden from the barrel) for a sibling; `isSiblingOf` tells `VectorTileLayer` to redraw in place instead of rebuilding its stores — and the sealed `ThemeLayer` hierarchy — `BackgroundThemeLayer`, `FillThemeLayer`, `LineThemeLayer`, `RasterThemeLayer`, `CircleThemeLayer`, `SymbolThemeLayer`, with `coversZoom()`, `matches()`, `filterReadsZoom` (`@internal` — the barrel exports this file, and nothing outside the package may set it — default true, so hand-built layers are never cached by `render/matched_features.dart`) and `readsGeometry` (`@internal`, default false) |
| `theme_reader.dart` | `ThemeReader` — turns style JSON layers into `ThemeLayer`s, mapping every paint/layout property to a typed prop with the spec's default as fallback; handles `{token}` templates in text fields; sets `filterReadsZoom` from a fresh parser's `readsZoom` straight after parsing the filter, and `readsGeometry`. Reads the root `state` defaults; when any layer reads `global-state`, the theme gets a `_GlobalStates` family that keeps the style document and compiles siblings on demand (the 8 most recent kept, so an unchanged state is the same instance; the default state keeps the plain id, others get `|state=<json>`). `idOf` is the id `read` gives a style (`StyleReader` suffixes the language to it) |
| `expression_parser.dart` | `ExpressionParser` — the largest file here (~1100 lines). Compiles modern expression arrays *and* legacy function/filter syntax into `Expr` closures: `let`/`var`, comparisons, `case`, `match`, `step`, `interpolate` (incl. cubic-bezier easing), the full math operator set, and property references. Tracks `readsZoom` — sticky, set by `["zoom"]` and by legacy functions keyed on the zoom — which the reader samples after a layer's filter |
| `expression.dart` | The compiled-expression runtime: `typedef Expr`, `EvalContext` (feature properties + zoom + vars), coercions (`toBoolean`/`toNumber`/`toColor`/`toStringValue`), and the typed property wrappers `DoubleProp`, `ColorProp`, `StringProp`, `BoolProp`, `NumListProp`, `StringListProp` — each with a fallback and an `isConstant` fast path |
| `theme.dart` | The compiled style model: `Theme` and the sealed `ThemeLayer` hierarchy — `BackgroundThemeLayer`, `FillThemeLayer`, `LineThemeLayer`, `RasterThemeLayer`, `HillshadeThemeLayer` (method, per-light directions/altitudes/shadow/highlight colours — at most `maxLights`, 4 — anchor, exaggeration, accent, resampling), `CircleThemeLayer`, `SymbolThemeLayer`, with `coversZoom()`, `matches()` and `filterReadsZoom` (`@internal` — the barrel exports this file, and nothing outside the package may set it — default true, so hand-built layers are never cached by `render/matched_features.dart`) |
| `theme_reader.dart` | `ThemeReader` — turns style JSON layers into `ThemeLayer`s, mapping every paint/layout property to a typed prop with the spec's default as fallback; handles `{token}` templates in text fields; sets `filterReadsZoom` from a fresh parser's `readsZoom` straight after parsing the filter |
| `css_color.dart` | CSS colour parsing: hex, `rgb()`/`rgba()`, `hsl()`/`hsla()` and the full named-colour table |
| `sprite_atlas.dart` | `SpriteAtlas` — one decoded sheet image plus named sub-rectangles parsed from the sprite index JSON, including `sdf` and `pixelRatio` per sprite |
| `sprite_packer.dart` | `padSpriteSheet` — repacks a loaded sheet with a 2 px transparent gutter around every sprite (aliases share one cell) so bilinear and mipmapped sampling never reaches a neighbouring icon. Called by `StyleReader` right after decoding; private, not exported. Falls back to the original sheet if readback fails or the packed sheet would exceed 4096 px on either side. Decodes through `decodeRgbaPixels`, which wraps `decodeImageFromPixels` in a guarded zone: that API only reports success, so a failed decode would otherwise leave the style load hanging. Not `ImageDescriptor.raw`, which goes through a straight-alpha BMP on web |

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
- **Global state is compiled in, not looked up.** `global-state`
  compiles to a constant, so an expression reading only global state is
  still `zoomOnly`, a filter reading it is still resolved once per
  prepared tile, and a different state is a different `Theme` (own id,
  own finished-tile cache). Never make it a runtime lookup without
  versioning those three caches.
- **Language is a document rewrite.** `StyleReader.language` never
  reaches the parser: `label_language.dart` rewrites the JSON before
  `ThemeReader` runs, so the parser records the translated name keys as
  ordinary references. Keep it that way — a parser-side lookup would
  have to register those keys itself or tile prep drops them.
- `SpriteAtlas.dispose()` disposes the sheet image; `Style.dispose()` fans out
  to sprites and providers.

### Testing Requirements

- `test/expression_test.dart` — operators, interpolation, legacy
  syntax, coercions, and the operators and semantics added from the spec
  fixtures
- `test/maplibre_expression_conformance_test.dart` — all 583 expression
  fixtures of maplibre-style-spec (generated into
  `test/fixtures/maplibre_expression_fixtures.dart`), read the way the
  renderer reads them; every divergence listed with its reason, and a
  listed fixture that starts passing fails the test, so the list only
  shrinks. Run it after any parser change; regenerate the fixtures when
  the spec moves
- `test/theme_reader_test.dart` — layer parsing and defaults,
  `filterReadsZoom` for absent, legacy, expression and zoom-reading
  filters, `readsGeometry`, and global state (defaults, siblings, the
  same instance per state)
- `test/css_color_test.dart` — every colour syntax
- `test/style_reader_cache_test.dart` — stale-while-revalidate behaviour
- `test/style_reader_sources_test.dart` — source URL resolution: relative
  TileJSON and tile templates (ArcGIS `root.json` shape), `{key}`
  substitution in TileJSON URLs
- `test/attribution_test.dart` — attribution parsing (links, entities,
  stray markup) and collection (source over TileJSON, dedup, order)
- `test/label_language_test.dart` — every `text-field` shape the
  language rewrite meets, unchanged output without a translation, and
  end to end through `StyleReader`, tile preparation and symbol layout

New expression operators need a case in `expression_test.dart` *and* an
explicit unsupported-input case proving the degradation path, and must
keep the conformance test green.

### Common Patterns

- `isConstant` on typed props lets the renderer hoist evaluation out of
  per-feature loops — set it whenever an expression compiles to a literal.
- A property whose default means "do nothing" — `*-translate`,
  `line-offset`, `line-blur`, `circle-blur`, the `*-sort-key`s, the
  patterns — is a nullable prop that stays null when the style leaves it
  unset (`_optionalDouble` / `_optionalNumList`), so the renderer skips
  its work with one null check instead of evaluating a zero per feature.
- `zoomOnly` on typed props memoizes the coerced result against
  `ctx.zoom`: the parser proves per property (via `parseForProperty`)
  that the expression reads no feature data, so a whole tile pass (one
  fixed zoom) evaluates it once. Anything that reads feature data —
  including `geometry-type`, `id` and legacy `$type`/`$id` — must set
  `_readsFeature`, or the memo returns stale values across features.
  To decide that a paint is the same for every feature, ask each prop
  (`isConstant || zoomOnly`), as `_paintFill`, `_paintExtrusion` and
  `_paintLine` do: a layer's empty
  `referencedProperties` does not prove it, since `id` and
  `geometry-type` read the feature without naming a property.
- `filterReadsZoom` decides whether the renderer may resolve a layer's
  filter once per prepared tile instead of per display tile. Anything a
  filter can reach that reads `ctx.zoom` must set `_readsZoom`, or a
  zoom-dependent filter is frozen at the first zoom it was resolved at.
  The flag is sticky across the parser, so the reader samples it before
  parsing anything else — erring towards true only costs the cache.
- Expressions are closures over parse-time state; they must not capture
  anything mutable or non-transferable (the zoom memo lives in the Prop
  wrappers, not in the closures).

## Dependencies

### Internal

- `logger.dart`, `cache/disk_cache.dart`, `provider/`, `tile_providers.dart`

### External

- `http`, `intl` (`number_format.dart` only), `dart:ui` (`Color`,
  `Image`), `dart:convert`

<!-- MANUAL: -->
