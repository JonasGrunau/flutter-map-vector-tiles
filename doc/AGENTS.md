<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# doc

## Purpose

Hand-written prose documentation that is too detailed for the README and too
narrative for `AGENTS.md` files. It explains *why* the package is shaped the
way it is, for humans evaluating or extending it.

## Key Files

| File | Description |
|------|-------------|
| `ARCHITECTURE.md` | The data-flow diagram (style → theme, camera → grid → store → rasterizer → labels), the rendering model, concurrency model, the cache table, the style engine, and what was deliberately changed versus `vector_map_tiles` |

## For AI Agents

### Working In This Directory

- **This file is hand-maintained, not generated** — edit it surgically rather
  than regenerating it, and preserve its voice.
- Update it whenever the **data flow, rendering model, concurrency model, cache
  layers or style engine** change. Its cache table and ASCII data-flow diagram
  are the two parts that silently go stale first.
- Keep it consistent with `lib/src/AGENTS.md` and the module-level `AGENTS.md`
  files: this is the narrative version of the same architecture, and the two
  contradicting each other is worse than either being terse.
- Root-level `README.md` is for users, `ARCHITECTURE.md` is for contributors,
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
