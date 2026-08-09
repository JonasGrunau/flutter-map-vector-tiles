<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# example

## Purpose

The runnable example app. It exists for two audiences: pub.dev (an example is
worth pub points and is the first thing users read) and manual verification —
rendering regressions such as label jitter, seam artifacts or zoom flashes are
only visible by driving a real map.

## Key Files

| File | Description |
|------|-------------|
| `lib/main.dart` | The whole example: `ExampleApp`, a `FlutterMap` with a `VectorTileLayer`, style URL and API key supplied via `--dart-define` (`MAPTILER_KEY`, `STYLE_URL`), defaulting to MapTiler streets-v2. Attribution comes from `style.attributions` — never hardcode a provider name here, the style URL is user-supplied |
| `pubspec.yaml` | Depends on the parent package by path |

## For AI Agents

### Working In This Directory

- **The example consumes only the public API**, imported with a `vt.` prefix.
  If a change here needs a new import from `src/`, that is a signal the public
  barrel is missing an export — decide that deliberately, don't reach around it.
- **Never commit an API key.** The key comes from `--dart-define` only; the
  default style URL keeps `{key}` as a placeholder that `StyleReader`
  substitutes.
- Keep it small. This is a demonstration of the layer, not a feature showcase —
  new options belong in the README's configuration section first.
- Use MapTiler style URLs for testing (this is the provider this package is
  developed against).

### Testing Requirements

```
flutter run --dart-define=MAPTILER_KEY=yourKey
```

Manual checks worth running after any rendering change: pan and zoom
continuously (no white flashes, no label jitter), rotate (labels stay upright),
zoom past the source max zoom (overzoom stays crisp), and reopen the map
(should paint instantly from the shared cache).

### Common Patterns

- `String.fromEnvironment` with a sensible default so `flutter run` works with
  nothing but a key.

## Dependencies

### Internal

- `flutter_map_vector_tiles` via a path dependency on the parent package

### External

- `flutter_map`, `latlong2`

<!-- MANUAL: -->
