<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-10 | Updated: 2026-11-18 -->

# screenshots

## Purpose

Every image the package shows of itself, and the pipeline that makes them.

- **The pub.dev gallery**: the `*-framed.webp` files here, referenced from
  `screenshots:` in `pubspec.yaml`. They **ship in the published package**
  (pub.dev requires the files inside the tarball; limit is 5 images, ≤ 4 MB
  each). The first entry doubles as the package thumbnail in pub.dev search
  results. They are portrait renders inside an Apple iPhone 17 bezel, and
  the README's top row shows the same four.
- **`readme/`**: plain landscape crops (1600×1000) embedded by `README.md`
  and the `doc/` pages. Not shipped: `.pubignore` excludes them, and
  pub.dev resolves the README's relative image paths against the GitHub
  repository's `main`.
- **`tool/`**: the capture pipeline. Not shipped.

## Key Files

| File | Description |
|------|-------------|
| `munich-liberty-framed.webp` | Munich old town, OpenFreeMap Liberty, zoom 16 |
| `buildings-3d-framed.webp` | Midtown Manhattan, Liberty, `ExtrusionMode.perspective`, zoom 16.4 |
| `zermatt-hillshade-framed.webp` | Zermatt, Liberty + Esri World Hillshade raster overlay, zoom 14.5 |
| `munich-dark-framed.webp` | Munich old town + Isar, OpenFreeMap Fiord (dark), zoom 15 |
| `readme/3d-flat.webp`, `readme/3d-perspective.webp` | The same Manhattan view with `ExtrusionMode.flat` and `.perspective` |
| `readme/heatmap.webp` | Munich with a heatmap of the OpenMapTiles `poi` points |
| `readme/query.webp` | The Frauenkirche selected through feature state after a tap |
| `readme/scripts.webp` | Tbilisi: Georgian and Latin labels from the style's glyphs |
| `readme/label-screen.webp`, `readme/label-tile.webp` | Munich turned by 30° with `LabelMode.screen` and `.tile` |
| `tool/shot_app.dart` | The app the shots are taken of: one map configured from the page URL (`style`, `lat`, `lon`, `zoom`, `rot`, `extrusion`, `labels`, `lang`); a tap selects a building. Outside `example/` to keep the example small, but built with the example's package configuration, and analysed as part of the root package |
| `tool/capture.mjs` | The shot list, the styles (OpenFreeMap's, with compact attribution and per-shot additions), a static server for the web build, and the Playwright capture in headless Chrome. Plain shots are converted straight into `readme/` |
| `tool/frame.py` | Puts a 1206×2622 capture into the bezel, clipped to the bezel's own screen cutout |
| `tool/contact.py` | Contact sheet of the raw captures (`tool/out/contact.png`), for reviewing them at a glance |
| `tool/capture.sh` | Runs all of the above |

## For AI Agents

### Regenerating the screenshots

```
BEZEL="/path/to/iPhone 17 - Black - Portrait.png" screenshots/tool/capture.sh
screenshots/tool/capture.sh heatmap query      # only these shots, unframed
```

It builds `tool/shot_app.dart` for the web (through `example/`), installs
Playwright into `tool/node_modules` on the first run, captures every shot
in `capture.mjs` in headless Google Chrome, converts and frames them, and
writes a contact sheet. Needs network (OpenFreeMap tiles and glyphs), node,
`cwebp`, and python3 with Pillow. The whole pipeline is key-free.

- **A new shot** is one entry in `shots` in `capture.mjs`: a view size, the
  URL parameters, optionally a click. A style variant (an extra layer or
  source) is a function next to `withPoiHeatmap`. Something the URL cannot
  express is a new parameter in `shot_app.dart`.
- **Look at every image you regenerate** — the contact sheet first, then
  the file at full size. Headless Chrome renders on SwiftShader, which is
  fine for looks; check that the map is complete, the 3D pass or heatmap
  actually drew, and labels are real text.
- **Scripts the style's glyphs do not cover come out as empty boxes in
  these captures** (seen with Japanese over Tokyo, 2026-11-18): Flutter
  web downloads the fallback fonts, but labels already shaped keep their
  boxes. Pick places whose scripts the glyphs cover (Latin, Greek,
  Cyrillic, Armenian, Georgian) until that is fixed.
- **The bezel** is Apple's official product bezel (Apple Design Resources,
  direct download
  `https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-17.dmg`;
  newer devices appear on developer.apple.com/design/resources under
  Product Bezels). `yes | hdiutil attach` past the embedded license and
  take `PNG/iPhone 17/iPhone 17 - Black - Portrait.png` (1350×2760,
  transparent screen cutout of exactly 1206×2622 at (72, 69)). The cutout
  is a squircle and the corners outside the shell are transparent too, so
  `frame.py` clips the map to the cutout itself, found by flood-filling
  the bezel's alpha from the centre; a rectangle or a `border-radius`
  approximation pokes out past the shell. Apple's license permits using
  the bezels to showcase your app; keep the framed shots on the
  latest-generation device. The bezel is not checked in.
- **Phone shots** are 603×1311 at `deviceScaleFactor: 2` → 1206×2622, the
  iPhone 17's native screen resolution (2× rather than the device's 3×
  keeps labels small and the attribution line short enough).
- **Attribution** stays in every image: the styles get compact
  `attribution` strings (`OpenMapTiles © OpenStreetMap`), which the app
  shows in a pill as `flutter_map | © …`. OpenFreeMap doesn't require
  attribution; OpenMapTiles and OSM do.
- **The three older framed shots** (Liberty, hillshade, dark) were made
  from `example/` by hand in August 2026, before this pipeline, and are
  not in `capture.mjs` yet. To redo them, add shots for them: Liberty at
  `[11.5755, 48.1373]` zoom 16; Fiord at `[11.5815, 48.135]` zoom 15
  (OpenFreeMap's `dark` style renders too flat for a gallery image);
  Liberty at `[7.7445, 46.0125]` zoom 14.5 with a raster source
  `https://services.arcgisonline.com/arcgis/rest/services/Elevation/World_Hillshade/MapServer/tile/{z}/{y}/{x}`
  (`tileSize: 256`, `maxzoom: 15`, attribution `Esri`) and a `raster`
  layer (`raster-opacity: 0.45`) inserted directly before the first
  `water*` layer.

### Working In This Directory

- Adding or renaming a gallery image means updating `screenshots:` in
  `pubspec.yaml` and the table above; pubspec descriptions are capped at
  160 characters by pub.dev.
- Keep the first pubspec entry the strongest image — it is the search
  thumbnail.
- Renaming a `readme/` image means updating every `README.md` and `doc/`
  page that embeds it.
- Verify with `dart pub publish --dry-run` that exactly the framed
  `.webp` files are in the file list: this `AGENTS.md`, `readme/` and
  `tool/` must stay excluded via `.pubignore`.
