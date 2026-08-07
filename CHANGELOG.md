# Changelog

## 0.3.0

- ✨ Curved line text: road labels now follow their line glyph by glyph,
  with MapLibre semantics — `text-max-angle` (labels on too-sharp bends
  are not placed), `text-keep-upright` (reading direction flips so text
  is never upside-down) and `text-rotation-alignment: viewport`
  (horizontal shield text). Glyph spacing/kerning comes from the full
  string layout; per-glyph collision boxes; nearly straight labels are
  drawn as a single rotated string for speed.
- Scripts with contextual shaping (Arabic, Indic, Thai, …) fall back to
  straight placement so glyphs are never mis-joined; labels longer than
  their line are dropped instead of sticking out (matches MapLibre).
- Along-line labels no longer wrap to multiple lines.
- ⬆️ `latlong2` constraint widened to `>=0.9.1 <0.11.0`, so 0.10.x resolves.
  Still compatible with flutter_map 8.2.0+, which pins `^0.9.1` until 8.3.1.
- 🧹 Source reformatted with the Dart formatter (no behaviour change).

## 0.2.0

- ✨ `text-variable-anchor` + `text-radial-offset`: labels try alternate
  anchors before being dropped on collision — dense areas keep far more
  POI and place labels visible (matches MapLibre behaviour).
- ✨ `fill-pattern` (and `fill-extrusion-pattern`): polygon fills render
  repeating sprite patterns (wetlands, glaciers, pedestrian zones),
  world-grid aligned across tile seams; missing sprites fall back to the
  color fill.
- 🐛 Bare literal arrays in style JSON (`text-offset: [0, 0.6]`,
  `text-font: [...]`, `line-dasharray: [2, 1]`, anchor lists) were
  mis-parsed as expressions and silently fell back to defaults —
  affected font stacks and label offsets in most real styles.
- `LabelPainter.paint` now returns the symbols that were actually drawn.

## 0.1.0

Initial release. 🎉

- `VectorTileLayer` for flutter_map ≥ 8 rendering MapLibre/Mapbox GL
  styles from MVT vector tile sources.
- Self-contained: built-in MVT decoder, style/expression engine
  (modern expressions + legacy filters/functions/tokens), sprite support.
- GPU-resident per-tile rasterization (`Picture.toImageSync`) with
  fade-in, ancestor-tile retention and provisional rendering from
  cached parent tiles (no white flashes on zoom).
- Screen-space label pass with global cross-tile collision, upright
  text under rotation, halo and sprite icon support.
- Worker-isolate decode pipeline with priority ordering and silent
  cancellation.
- Deterministic LRU memory caches (byte budgets) and TTL + size-capped
  disk cache.
- `StyleReader` for style.json / TileJSON / sprites with `{key}`
  substitution, tolerant of real-world provider quirks
  (MapTiler, OpenFreeMap, Stadia, ArcGIS, Protomaps).
- `TileOffset.maplibre` default for correct 512px-convention rendering.
