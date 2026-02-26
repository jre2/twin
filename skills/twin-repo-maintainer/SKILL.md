---
name: twin-repo-maintainer
description: Use when changing or reorganizing Twin's Odin codebase so declarations, data tables, and systems stay consistent with the repository's architecture and style conventions.
---

# Twin Repository Maintainer

## Use This Skill When
- The task is a structural cleanup or reorganization pass.
- New types, fields, or systems need to be inserted in the right place.
- Readability or maintainability is being improved without changing gameplay behavior.

## Core Rule
Organize by dependency first, then by gameplay domain: declare foundational things before consumers, keep related concepts adjacent, and avoid catch-all "utility" buckets.

## Organization Checklist
1. Keep top-level ordering consistent:
- compile-time constants and feature flags
- enums (base types adjacent to their subtypes)
- static/template data definitions (`WeaponDef`, `EntityDef`, visual/config data)
- runtime instance/state types (`WeaponInput`, `WeaponInstance`, `Entity`, `GameState`)
- globals and lookup tables (`WeaponDB`, `VizDB`, `st`)
- procedures grouped by frame flow and system area
2. Group procedures by the input -> update -> render pipeline, with support procedures near their callers.
3. Prefer scoped blocks over one-off global helpers when logic is local to a larger procedure.
4. If a helper is still useful but only called once, make it a local `:: proc` at the top of the parent procedure.
5. Keep weapon/enemy balance data baked into source, not external config files.

## Odin Conventions To Enforce
- Use `for &x in xs` for in-place mutation, `for x in xs` for copies.
- Prefer `for i in 0..<len(xs)` unless collection length changes during iteration.
- Use `x if cond else y` for ternaries.

## Validation
- `odinfmt -w src/main.odin`
- `cd bin && odin check ../src`
- `cd bin && odin test ../src`

## Output Expectations
- Preserve behavior unless behavior changes are explicitly requested.
- Keep diffs focused and mechanical for organization-only tasks.
- Update `doc/TODO.md` when task status changes are part of the request.
