# flutter_map_vector_tiles

@AGENTS.md

## Documentation is part of the change, never a follow-up

Any change to behaviour, structure or the public API must update the affected
documentation **in the same change**. Docs that describe the previous state are
treated as a bug, not as debt.

Keep these in sync with the code:

| file | keep accurate when |
| --- | --- |
| `AGENTS.md` | files move or are added/removed, module responsibilities shift, workflows or conventions change |
| `doc/ARCHITECTURE.md` | the data flow, rendering model, concurrency model, cache layers or style engine change |
| `README.md` | anything user-visible changes — public API, options, defaults, supported style features, offline behaviour, limitations |
| `CHANGELOG.md` | every user-visible change, under the version it ships in |

Before declaring work done, re-read the sections these files have about the
area you touched and correct anything that no longer holds. If a doc claims a
limitation you just removed (or vice versa), fix that sentence too.

## README must track the package's identity

Whenever anything identifying the package changes, update `README.md` in the
same change:

- **Version in the install snippet** — `flutter_map_vector_tiles: ^X.Y.Z` under
  `## 🚀 Quick start → 1. Install` must match `version:` in `pubspec.yaml`.
  Bumping the pubspec version without touching the README is incomplete.
- **Dependency constraints in that snippet** (e.g. `flutter_map: ^8.2.0`) must
  match the constraints in `pubspec.yaml`.
- **Package name, repository / issue-tracker URLs, badges** — must match
  `pubspec.yaml`. The flutter_map badge encodes a version range; update it when
  the `flutter_map` constraint moves.
- **SDK / Flutter minimums** stated in prose must match `environment:`.

## Release gate

Before publishing (see also `CHANGELOG.md`):

1. `dart format .` — there is no CI; format drift silently costs pub points.
2. `flutter analyze` — clean.
3. `flutter test` — all green.
4. `dart pub publish --dry-run` and a pana run; the package holds full pub points.
