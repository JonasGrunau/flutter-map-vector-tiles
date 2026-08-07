# Changelog

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
