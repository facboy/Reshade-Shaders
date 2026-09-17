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
  `FDN` (frames to deactivate), `EveryN`.
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

Adding mask 5 (the pattern generalizes to any slot) touches **eight places**, all in
`UIDetectMulti.fx` except the header and the texture:

1. `UIDetectMulti.fxh` — widen the `UIDM_MASK_COUNT` comment range and add the new `UIPixelCoord_UINr`
   / `UIPixelRGB` entries.
2. Uniform block — `tolerance13/14/15`, `FA13/14/15`, `FD13/14/15`, `Every13/14/15` inside
   `#if (UIDM_MASK_COUNT > 4)`.
3. Texture/sampler block — `texUIDetectMaskMulti5` (with `source="UIDETECTMASKRGBMULTI5.png"`),
   `texUIDetectMulti5`, `texUIDetectTimer5` and their samplers, inside the same guard.
4. Pixel shaders — `PS_UIDetect5`, `PS_UIDetectTimerSetup5`, `PS_UIDetectTimer5`.
5. `PS_Antibloom` — `FTD13/14/15` plus the `mask5` blend block.
6. `PS_RestoreColor` — `FTD13/14/15` plus the `mask5` blend block.
7. `UIDetectSetup` technique — the pass binding `PS_UIDetectTimerSetup5` → `texUIDetectTimer5`.
8. `UIDetectMulti` technique — the passes binding `PS_UIDetect5` → `texUIDetectMulti5` and
   `PS_UIDetectTimer5` → `texUIDetectTimer5`.

Also drop the matching `Textures/UIDetectMaskRGBMulti5.png` in place.

The historical bugs in this area were exactly the two easy-to-miss kinds: a guard written as
`> 3` for the mask 5 block instead of `> 4`, and a pass pointing at `PS_UIDetect4` /
`texUIDetectMulti4` while sitting under the `> 4` guard. When editing these blocks, always check the
guard number **and** that the referenced pixel shader / render target / sampler / texture all use the
same slot number as the guard.

## Editing conventions

- Keep the existing formatting: this is `.fx`/`.fxh` HLSL, not C++. The file works fine as-is; do not
  reformat, re-indent or convert line endings wholesale. Mixing tabs and spaces inside a block is
  already normal here.
- Preserve the line-ending of the file you touch — `.fxh` and `Reshade overall effect.fx` are CRLF,
  `UIDetectMulti.fx` and `README.md` are LF. Do not let an editor normalize them.
- Follow the naming scheme: `toleranceN`, `FAN`, `FDN`, `EveryN`, `PS_UIDetectN`,
  `PS_UIDetectTimerN`, `PS_UIDetectTimerSetupN`, `texUIDetectMultiN`, `texUIDetectTimerN`,
  `UIDetectMaskMultiN`, `FTDN`.
- Shader code comments are sparse, short and in English (`//UINr 13`). Match that; do not add
  tutorial-style narration to the HLSL.
- `README.md` is written for non-programmers in a conversational tone. Keep that voice when editing
  it, and update it whenever a feature it describes changes.
- Known staleness in `README.md`: it still mentions `UIDM_EVERYPIXEL`, which no longer exists — the
  per-element `EveryN` uniforms replaced it — and it refers to "the other 2-14 masks", a leftover from
  an earlier layout with more slots. There are 5 masks and 15 UI elements. Do not reintroduce either.

## Verification

Nothing here is testable automatically, so verification is manual and review-based:

- Sanity-check every new block with a repository-wide search for the affected symbols
  (`UIDM_MASK_COUNT`, `PS_UIDetectN`, `texUIDetectMultiN`) and confirm the guards and slot numbers
  line up as described above.
- Confirm the new mask PNG exists in `Textures/` with a name matching the `source=` attribute.
- Real end-to-end testing means loading the three techniques in ReShade in a game, which an agent
  cannot do: state that clearly instead of claiming the change is verified. Reviewing a screen
  capture is the next best thing.
- Set `UIDM_DIAGNOSTICS` to 1 to get the in-game crosshair, pixel coordinate sliders and live RGB
  readout for calibrating pixels; it must be `0` in anything shipped.

## Known latent issues (reviewed, deliberately not fixed)

These were found by reading the shader and simulating its indexing logic. None of them are visible in
the checked-in configuration, so they are recorded here rather than patched:

- **Out-of-bounds array read.** In every `PS_UIDetectN`, the inner `for (int i=0; i < 3; i++)` loop
  tests `if (uinumber == PIXELNUMBER){break;}` only *after* it has read
  `UIPixelCoord_UINr[uinumber]` and `UIPixelRGB[uinumber]`. Because the loop advances `uinumber` past
  the last entry, the final iteration indexes `PIXELNUMBER`. The default one-entry configuration
  already does this, and so does any configuration where the searched-for UI number is the last entry
  (e.g. UINr 10 with `PIXELNUMBER 11`). The out-of-range read usually yields zeros and the `.z ==`
  guard rejects it, so the visible effect is normally nil, but the access is genuinely undefined.
  A bound such as `i < 3 && uinumber < PIXELNUMBER` would fix it, provided the `i -= 1` retry for
  repeated UI numbers is kept — the retry intentionally re-runs an iteration until it has consumed
  every entry sharing one UI number.
- **Zero tolerance is a dead state.** The tolerance sliders use `ui_min = 0`, but the shader tests
  `diff.r < tolerance.r`, which can never hold for a value of 0. A tolerance of 0 therefore makes
  that UI element permanently undetectable instead of making detection exact.
- **`PS_Antibloom` ignores `UIDM_INVERT`.** `PS_RestoreColor` swaps `color`/`colorOrig` when
  `UIDM_INVERT == 1`, but `PS_Antibloom` always uses the non-inverted assignment, so inverted mode
  combined with `UIDM_ANTIBLOOM = 1` is inconsistent.

## Repository rules

- Do not start work that adds or modifies files while `git status` shows uncommitted changes; stop
  and report the dirty state instead.
- Do not commit unless the user asks for it. When committing, append the co-author trailer:
  `--trailer "Co-authored-by: Junie <junie@jetbrains.com>"`.
- Write commit subjects in the imperative mood, lowercase after the prefix, matching the existing
  history (e.g. `fix UIDetectMulti mask 13 guard and mask 5 pass`).
- Never edit the mask PNGs by hand or overwrite a user's mask; they are authored by users in an image
  editor (see `README.md`).
