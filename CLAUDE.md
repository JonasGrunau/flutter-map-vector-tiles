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

## CHANGELOG entries follow a fixed shape

Work in progress accumulates under `## Unreleased`; releasing renames that
heading to the version. Every version section looks like this, and a release
is not ready until its section does:

```markdown
## 2.1.1

Style attribution and MVT decode performance.

- ✨ **Style attribution**: `Style.attributions` exposes …
- ⚡ Zigzag decoding is branchless again, recovering …
```

- **Heading** — `## X.Y.Z`, newest first, no date, no link.
- **Summary line** — a sentence or two directly under the heading, then a
  blank line. It names the *theme* of the release, so someone scanning the
  version list can tell whether to care; it does not enumerate the bullets
  below it. Every version has one — never release without it.
- **Bullets** — one per user-visible change, each opening with the emoji for
  its kind, and **grouped by kind in this order**: 💥 breaking, ✨ feature,
  🎨 rendering / style support, ⚡ performance, 🐛 fix, 🌐 platform,
  ✈️ offline, 📚 docs, 📦 packaging or pub.dev metadata, ⬆️ dependency
  bump, 🧹 cleanup. A new bullet is inserted into its kind's group — never
  just appended to the section — with the more significant change first
  within the group. Headline features may bold a short lead-in
  (`- ✨ **Style attribution**: …`). Describe the change from the user's
  side, and for fixes say what went wrong before.

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

Three workflows, all in `.github/workflows/` and all on the Flutter version
pinned in `.tool-versions`:

- `checks.yml` — the shared suite: `dart format` changes nothing,
  `flutter analyze` is clean, `flutter test` is green on the VM and on Chrome,
  `dart pub publish --dry-run` has no warnings, and optionally pana at full
  points. Never triggered on its own.
- `ci.yml` — runs `checks.yml` (without pana) on every push to `main` and
  every PR into it.
- `publish.yml` — runs when a `vX.Y.Z` tag is pushed. It refuses to publish
  unless the tagged commit is on `main`; the tag, `version:` in
  `pubspec.yaml`, the README install snippet (version and `flutter_map`
  constraint) and the newest `CHANGELOG.md` heading agree, and that section
  has its summary line; and `checks.yml` passes **with pana**. Only then
  does its `publish` job upload, authenticated by OIDC — there is no
  pub.dev secret in the repo.

Shipping a version:

1. Make sure CI is green on `main`, and run pana locally — CI doesn't run
   it, and a red release workflow costs a re-tag.
2. Commit `Release X.Y.Z`: rename `## Unreleased` to `## X.Y.Z`, write its
   summary line, bump `version:` and the README install snippet.
3. `git tag vX.Y.Z && git push --atomic origin main vX.Y.Z`.

If the release workflow fails before `publish`, nothing reached pub.dev: fix
it on `main`, then move the tag (`git tag -f vX.Y.Z && git push -f origin
vX.Y.Z`). A flaky test only needs "Re-run failed jobs".

**No GitHub Releases.** The release notes would only repeat
`CHANGELOG.md`, which ships in the package and is what pub.dev's
changelog tab renders — a second copy on GitHub is one more place to
forget. The tags stay, and they now do the publishing: the workflow
uploads a clean checkout of `vX.Y.Z`, so the tag is exactly the source
that became that version, and what makes `git diff v2.5.0..v2.6.0` or a
checkout of the version a bug report names possible. A manual
`dart pub publish` still works as a fallback, but it uploads the
*working tree*, not a commit — only use it from a clean checkout of the
tag.
