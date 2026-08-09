<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# provider

## Purpose

The byte-fetching boundary of the package: given a `TileKey`, produce raw tile
bytes. Everything here is public API — users implement `VectorTileProvider` to
plug in custom sources (bundled assets, MBTiles, authenticated endpoints).
Providers serve both MVT vector data and, via `RasterTileSource`, raster
imagery.

## Key Files

| File | Description |
|------|-------------|
| `vector_tile_provider.dart` | The contract: `abstract class VectorTileProvider` (`load(TileKey, {CancellationToken})`, `dispose()`) and the sealed `TileResponse` hierarchy — `TileResponseData`, `TileResponseNotFound`, `TileResponseCancelled`, `TileResponseError` |
| `network_vector_tile_provider.dart` | HTTP provider over a `{z}/{x}/{y}` URL template; de-duplicates concurrent requests for the same URL, maps 404/204/empty to `NotFound`, 5xx and socket failures to `Error`, and honours the cancellation token |
| `memory_vector_tile_provider.dart` | Serves tiles from an in-memory map — used by tests and for bundled/offline tile sets |
| `pmtiles/pmtiles_format.dart` | PMTiles v3 binary format: 127-byte header, directory decoding (delta varints, run lengths, contiguous offsets), Hilbert z/x/y→TileID. Web-safe by construction — 64-bit values use multiply/add arithmetic, never bitwise ops |
| `pmtiles/pmtiles_vector_tile_provider.dart` | `PmTilesVectorTileProvider` — serves tiles from a single-file PMTiles archive over HTTP range requests (`pmtiles://` sources). `open()` fetches header + root directory once; leaf directories are LRU-cached; gzip only (brotli/zstd rejected at open) |
| `pmtiles/pmtiles_gunzip_io.dart` / `pmtiles_gunzip_web.dart` | Conditional-import gunzip: `dart:io` zlib natively, the browser's `DecompressionStream` on web |

## For AI Agents

### Working In This Directory

- **The response type is the error-handling design.** Absence and cancellation
  are ordinary states, not exceptions. `NotFound` renders as an empty tile and
  is cached as such; only `Error` is retryable. Adding a variant to the sealed
  class is deliberate — every `switch` over it will (correctly) fail to compile
  until handled.
- Cancellation must short-circuit *before* and *after* the network await, and
  return `TileResponseCancelled` rather than throwing.
- `NetworkVectorTileProvider` shares one in-flight future per URL; the
  `whenComplete` cleanup that removes the entry must stay a block body (see
  `cache/AGENTS.md` for the same footgun).
- API keys reach providers already substituted by `StyleReader`; when logging
  URLs, keep them redacted (`StyleReader._redactKey` sets the precedent).

### Testing Requirements

Most tests inject `MemoryVectorTileProvider` rather than hitting the network.
Network behaviour is exercised through `http` client injection — keep the
client a constructor parameter so tests can substitute a mock client.

### Common Patterns

- `dispose()` on a provider closes its HTTP client; `TileProviders.dispose()`
  fans out to all of them, and the layer calls that on teardown.

## Dependencies

### Internal

- `core/tile_key.dart`, `core/cancellation.dart`

### External

- `http` — `Client`, `ClientException`

<!-- MANUAL: -->
