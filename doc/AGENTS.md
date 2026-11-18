<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-11-18 -->

# doc

## Purpose

Hand-written prose documentation that is too detailed for the README and too
narrative for `AGENTS.md` files. Two kinds live here: the **user reference**
the README links to (what every option does, what is supported, where the
result differs from MapLibre), and `ARCHITECTURE.md`, which explains *why*
the package is shaped the way it is, for humans evaluating or extending it.
All of it ships in the package.

## Key Files

| File | Description |
|------|-------------|
| `CONFIGURATION.md` | Every `VectorTileLayer` and `StyleReader` option, `TileOffset`, the memory caches and `clearMemoryCache`, the render pump's frame budget, the DevTools timeline events, memory numbers next to `vector_map_tiles` |
| `TILE_SOURCES.md` | The tested-provider table, manual wiring, PMTiles, MBTiles, custom `VectorTileProvider`s, raster and DEM sources, offline behaviour, web support |
| `STYLE_SUPPORT.md` | Layer types, properties not drawn, icons, symbol properties, heatmaps, 3D buildings, expressions, global state |
| `LABELS.md` | Label placement and collision behaviour, fonts and glyphs, `LabelMode.screen` vs `.tile`, label language |
| `QUERYING.md` | `queryRenderedFeatures`, `retainAllProperties`, feature state |
| `TROUBLESHOOTING.md` | One heading per symptom: cause and fix |
| `ARCHITECTURE.md` | The data-flow diagram (style → theme, camera → grid → store → rasterizer → labels), the rendering model, concurrency model, the cache table, the style engine, and what was deliberately changed versus `vector_map_tiles` |

## For AI Agents

### Working In This Directory

- **These files are hand-maintained, not generated** — edit them surgically
  rather than regenerating them, and preserve their voice.
- **The user reference pages are where user-visible detail goes.** The
  README is a short overview; a new option, limitation or measurement is
  written into the page it belongs to (see the sync table in `CLAUDE.md`),
  and reaches the README only if it changes the overview. Each page opens
  with a contents list of its `##` headings — keep it in step. Links
  between pages are relative to `doc/`; links to the rest of the repo start
  with `../`. Images come from `../screenshots/readme/`.
- Update `ARCHITECTURE.md` whenever the **data flow, rendering model, concurrency model, cache
  layers or style engine** change. Its cache table and ASCII data-flow diagram
  are the two parts that silently go stale first.
- Keep it consistent with `lib/src/AGENTS.md` and the module-level `AGENTS.md`
  files: this is the narrative version of the same architecture, and the two
  contradicting each other is worse than either being terse.
- Root-level `README.md` and the reference pages are for users,
  `ARCHITECTURE.md` is for contributors,
  `AGENTS.md` files are for agents. Don't duplicate quick-start material here.

### Testing Requirements

None (prose). Verify claims against the code before changing them — several
statements here are precise (`Picture.toImageSync`, max 2× image scaling,
isolate pool with priority queue) and are load-bearing for readers deciding
whether to adopt the package.

## Dependencies

### Internal

- Describes `lib/src/` in its entirety

<!-- MANUAL: -->
