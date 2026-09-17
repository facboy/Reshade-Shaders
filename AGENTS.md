# AGENTS.md

Guidance for AI agents working in this repository.

## What this project is

A ReShade shader pack built around **UIDetectMulti**: it detects on-screen game UI elements by
sampling a few chosen pixels, then uses hand-authored mask images to protect those UI elements from
ReShade post-processing effects (or, in inverted mode, to apply effects only to them).

Author: Kaiser. Version 1.6.0, based on work from Brussels1. Licensed CC BY 4.0 (`LICENSE`).

## Repository layout

| Path | Role |
| --- | --- |
| `Shaders/UIDetectMulti.fx` | The shader itself: uniforms, textures, pixel shaders, techniques. ~1300 lines. |
| `Shaders/UIDetectMulti.fxh` | User-facing config header: `UIDM_*` defines and the `PIXELNUMBER` pixel tables. |
| `Shaders/Reshade overall effect.fx` | Tiny helper effect that stores the back buffer before effects and blends it back after, with an `Intensity` slider. |
| `Textures/UIDetectMaskRGBMulti*.png` | Mask images, one per mask slot. Masks 1–4 are the real 2560x1440 masks authored for Dark Souls Remastered; `UIDetectMaskRGBMulti5.png` is an unused 1920x1080 pure-white placeholder. |
| `README.md` | End-user guide: placement order, how to author masks, how to pick pixels. |
| `docs/review.md` | Code review of the shader pack — findings, evidence and open issues. Read it before changing the shader logic. |

There is **no build system, no dependency manifest, no test suite and no CI**. Shaders are compiled by
ReShade at runtime; `ReShade.fxh`, `ReShadeUI.fxh` and `DrawText.fxh` are supplied by the ReShade
installation and are deliberately not vendored here. Never add a build script for the sake of it, and
never vendor ReShade's own headers.

## Core model

- `PIXELNUMBER` in `UIDetectMulti.fxh` is the number of sampled pixel entries; each entry pairs one
  `float3(x, y, UINr)` in `UIPixelCoord_UINr` with one `float4(r, g, b, UINr)` in `UIPixelRGB`.
- One mask slot carries **three** UI elements, one per RGB channel of the mask PNG.
- UI element numbers (`UINr`) are global and grouped by mask:
  mask 1 = 1,2,3 | mask 2 = 4,5,6 | mask 3 = 7,8,9 | mask 4 = 10,11,12 | mask 5 = 13,14,15.
- `UIDM_MASK_COUNT` (1–5) enables mask slots. Every block for mask *n* is guarded by
  `#if (UIDM_MASK_COUNT > n-1)`, i.e. mask 1 → `> 0` (unguarded), mask 2 → `> 1`, … mask 5 → `> 4`.
  Setting it higher than the number of masks that actually have entries costs render targets and
  passes for nothing, so keep it in step with `PIXELNUMBER`.
- Per element there are four uniforms: `toleranceN` (RGB), `FAN` (frames to activate),
  `FDN` (frames to deactivate), `EveryN`. The `toleranceN` sliders start at `ui_min = 1` on purpose:
  detection tests `diff < tolerance`, so a floor of 0 would make the element impossible to detect.
- `EveryN` is a `bool`, so it carries the matching `__UNIFORM_SLIDER_BOOL1` annotation; the float
  uniforms use `__UNIFORM_SLIDER_FLOAT1`/`_FLOAT3`. Keep the annotation and the declared type in step.
- An element may have **several** entries sharing one `UINr`, which is how a pixel whose colour
  changes is handled: the list is scanned until every entry of that UI number has been consumed, and
  the element counts as detected if any single colour matches. Placeholder rows written as
  `float3(0,0,UINr)` / `float4(0,0,0,UINr)` for elements that are not in use keep the numbering
  aligned and are harmless.
- The activate/deactivate timing is a rolling counter stored in the 1x1 `texUIDetectTimer*` render
  targets. `PS_UIDetectN` advances it; `PS_UIDetectTimerN` copies it forward; `UIDetectSetup`
  (hidden, `timeout = 1`) resets it with `PS_UIDetectTimerSetupN`.

## Techniques and render order

Three techniques must be placed in this order in the ReShade effect list (see `README.md`):

1. `UIDetectSetup` (hidden, runs once) and `UIDetectMulti` — must be **first**, because it samples the
   untouched back buffer.
2. `UIDetectMulti_Before` — stores the masked pixels; put shaders you do **not** want touching the UI
   between this and the next technique.
3. Any third-party effects.
4. `UIDetectMulti_After` — restores the stored masked pixels on top.

`UIDM_ANTIBLOOM = 1` makes the area behind the masks black inside `UIDetectMulti_Before` to stop
bloom bleeding.

## Adding or removing a mask slot

Each slot is defined once by macros, so adding mask 5 (the pattern generalizes to any slot) now
touches **four places**, all in `UIDetectMulti.fx` except the header and the texture:

1. `UIDetectMulti.fxh` — widen the `UIDM_MASK_COUNT` comment range and add the new `UIPixelCoord_UINr`
   / `UIPixelRGB` entries.
2. Uniform block — inside `#if (UIDM_MASK_COUNT > 4)`, three `UIDM_ELEM(13)`, `UIDM_ELEM(14)`,
   `UIDM_ELEM(15)` invocations (element number only; the mask label follows from it).
3. Everything else about the slot comes from one invocation each, under the same guard:
   - `UIDM_SLOT(5, UIDETECTMASKRGBMULTI5.png)` in the texture/sampler block,
   - `UIDM_TIMER_SHADERS(5, 13, 14, 15)` in the pixel shader section,
   - `UIDM_TIMER_PASS(5)` in `UIDetectSetup` and `UIDM_DETECT_PASS(5)` in `UIDetectMulti`,
   - `PS_UIDetect5` itself, which is a timer read, an `FTA` float3 and one `UIDM_DetectChannels(13, …)`
     call, plus its three `UIDM_BlendChannel` calls in `PS_Antibloom` and `PS_RestoreColor`.
4. Drop the matching `Textures/UIDetectMaskRGBMULTI5.png` in place.

`UIDM_SLOT` takes the PNG filename as an argument because slot 1's file has no number
(`UIDETECTMASKRGBMULTI.png`); every texture and sampler identifier is suffixed, slot 1 included.
The `#if` guard must still be written out around each invocation, because a preprocessor directive
cannot appear inside a macro body.

The historical bugs in this area were a guard written as `> 3` for the mask 5 block instead of `> 4`,
and a pass pointing at slot 4's shader while under the `> 4` guard. The second kind is now
**structurally impossible**: `UIDM_DETECT_PASS(5)` cannot reference anything but `PS_UIDetect5` and
`texUIDetectMulti5`, and the number appears once per invocation rather than five times. The guard is
the only place the slot number is still repeated, so that is the one thing to check.

`UIDM_DetectChannels` and `UIDM_BlendChannel` are ordinary helper functions, not macros, so the
runtime logic stays steppable and greppable. HLSL inlines them, so they cost no call.

## Editing conventions

- Keep the existing formatting: this is `.fx`/`.fxh` HLSL, not C++. The file works fine as-is; do not
  reformat, re-indent or convert line endings wholesale. Mixing tabs and spaces inside a block is
  already normal here.
- Preserve the line-ending of the file you touch — `.fxh` and `Reshade overall effect.fx` are CRLF,
  `UIDetectMulti.fx` and `README.md` are LF. Do not let an editor normalize them.
- Follow the naming scheme: `toleranceN`, `FAN`, `FDN`, `EveryN`, `PS_UIDetectN`,
  `PS_UIDetectTimerN`, `PS_UIDetectTimerSetupN`, `texUIDetectMultiN`, `texUIDetectTimerN`,
  `texUIDetectMaskMultiN`, `UIDetectMaskMultiN`, `FTDN`. All of these are suffixed, **slot 1
  included** (`texUIDetectMulti1`, `UIDetectMulti1`), so the slot macros need no special case. The
  three technique names, `UIDetectSetup` and the slot-agnostic `texColorBeforeMulti` /
  `ColorBeforeMulti` deliberately are not suffixed; the `source=` PNG filenames keep their original
  names (`UIDETECTMASKRGBMULTI.png`), since a user's mask file must not be renamed.
- Shader code comments are sparse, short and in English (`//UINr 13`). Match that; do not add
  tutorial-style narration to the HLSL.
- Update `README.md` in the same conversational, non-programmer voice whenever a feature it describes
  changes; it documents the placement order and the mask/pixel workflow users follow.

## Verification

Nothing here is testable automatically, so verification combines a review pass with an offline
compile check:

- `uv run tools/verify_shaders.py init` fetches the ReShade headers pinned in the script, then
  `uv run tools/verify_shaders.py check --baseline tools/.work/before.json` compiles every pixel
  shader across `UIDM_MASK_COUNT` 1-5 in four define variants and reports instruction counts, opcode
  histograms and bytecode hashes. It also compares the uniform inventory and the technique pass
  bindings, and fails if a mask PNG filename changes. Keep its `tools/.work/` output out of commits
  (already in `.gitignore`).
  - It **fails loudly on missing data** by design. An earlier version reported a clean pass while
    emitting no bytecode at all, which is the failure mode to watch for when changing it.
  - It cannot see *reordering*. Instruction count and opcode histogram are the cost that matters; if
    you need to prove a rewrite is equivalent rather than merely equal-cost, compare the source
    token streams as well.
- Sanity-check every new block with a repository-wide search for the affected symbols
  (`UIDM_MASK_COUNT`, `PS_UIDetectN`, `texUIDetectMultiN`) and confirm the guards and slot numbers
  line up as described above.
- Confirm the new mask PNG exists in `Textures/` with a name matching the `source=` attribute.
- Real end-to-end testing means loading the three techniques in ReShade in a game, which an agent
  cannot do: state that clearly instead of claiming the change is verified. Reviewing a screen
  capture is the next best thing.
- Set `UIDM_DIAGNOSTICS` to 1 to get the in-game crosshair, pixel coordinate sliders and live RGB
  readout for calibrating pixels; it must be `0` in anything shipped.
- `State_Pixel_Color` is inside `#if (UIDM_DIAGNOSTICS == 1)` and positions its readout in absolute
  render-target pixels (that is what `DrawText_String`'s `pos`/`size` mean), so it scales the layout by
  `BUFFER_HEIGHT / 1080.0`. Keep any overlay anchored to the buffer size the same way.
- Known open issues are listed in `docs/review.md`; check whether your change touches one, and update
  that document rather than `AGENTS.md` when a finding is fixed or a new one is confirmed.

## Repository rules

- Do not start work that adds or modifies files while `git status` shows uncommitted changes; stop
  and report the dirty state instead.
- Do not commit unless the user asks for it. When committing, append the co-author trailer:
  `--trailer "Co-authored-by: Junie <junie@jetbrains.com>"`.
- Write commit subjects in the imperative mood, lowercase after the prefix, matching the existing
  history (e.g. `fix UIDetectMulti mask 13 guard and mask 5 pass`).
- Never edit the mask PNGs by hand or overwrite a user's mask; they are authored by users in an image
  editor (see `README.md`).
