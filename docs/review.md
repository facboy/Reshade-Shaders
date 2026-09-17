# Code review — UIDetectMulti shader pack

Reviewed revision: `0629675`; refactor in section 8 reviewed against the same baseline
Date: 2026-09-17

Scope: `Shaders/UIDetectMulti.fx`, `Shaders/UIDetectMulti.fxh`,
`Shaders/Reshade overall effect.fx`, `Textures/UIDetectMaskRGBMulti*.png`, `README.md`.

Method: line-by-line reading of the HLSL, a simulation of the `PS_UIDetectN` indexing logic against
the checked-in `PIXELNUMBER` / `UIPixelCoord_UINr` tables, and a decode of every mask PNG (zlib
inflate plus PNG scanline unfiltering) to sample the configured coordinates in their own channel. The
section 8 refactor adds offline compilation with `fxc`, before and after, via
`tools/verify_shaders.py`. No runtime verification was possible: the shaders only compile inside
ReShade in-game.

## Summary

| # | Finding | Severity | Status |
| --- | --- | --- | --- |
| 1 | Out-of-bounds array read in every `PS_UIDetectN` inner loop | Latent, undefined behaviour | Fixed |
| 2 | A tolerance of 0 makes its UI element permanently undetectable | Minor, latent | Fixed |
| 3 | `PS_Antibloom` ignores `UIDM_INVERT`, unlike `PS_RestoreColor` | Minor | Fixed |
| 4 | All shipped mask PNGs were blank white placeholders | Blocking for the feature | Fixed |
| 5 | Mask 5 uniform guard and technique pass referenced the wrong slot | Functional bug | Fixed |
| 6 | `README.md` describes features and a mask count that no longer exist | Documentation | Fixed |
| 7 | Misc annotation, naming and dead-code inconsistencies | Cosmetic | 7.1-7.4 and 7.6 done; 7.5 reclassified as not a defect |
| 8 | The file repeated five slots and fifteen elements by hand | Maintainability | Fixed — duplication removed, output unchanged |

## 1. Out-of-bounds array read in `PS_UIDetectN` (fixed)

In all five `PS_UIDetectN` functions the inner loop was shaped like this
(`PS_UIDetect1` at `Shaders/UIDetectMulti.fx:707-723`, the pattern repeats for masks 2-5):

```hlsl
for (int i=0; i < 3; i++){
    pixelCoord = UIPixelCoord_UINr[uinumber].xy * BUFFER_PIXEL_SIZE;
    pixelColor = round(tex2D(BackBuffer, float2(pixelCoord)).rgb * 255);
    uiPixelColor = UIPixelRGB[uinumber].rgb;
    ...
    if (uinumber == PIXELNUMBER){break;}
    if (uinumber < PIXELNUMBER - 1){
        if (UIPixelCoord_UINr[uinumber].z == UIPixelCoord_UINr[uinumber + 1].z){i -= 1;};
    }
    uinumber += 1;
}
```

Two things combine badly:

- The guard `if (uinumber == PIXELNUMBER){break;}` sits **after** the reads of
  `UIPixelCoord_UINr[uinumber]` and `UIPixelRGB[uinumber]` in the same iteration.
- `uinumber` is incremented once per iteration, so on the iteration where it reaches `PIXELNUMBER`
  the reads have already happened.

Result: the final iteration always indexes `PIXELNUMBER`, one past the last valid element. This is not
hypothetical — the checked-in configuration (`PIXELNUMBER 11`, UINr 10 as the last entry) makes
`PS_UIDetect4` read index 11, and the original single-entry default (`PIXELNUMBER 1`, one entry) makes
`PS_UIDetect1` read index 1.

Simulated traces for the current tables (iterations shown as `(i, uinumber)`; the index is read at
the top of the iteration, before any break check):

| Function | UINr | Iterations before the fix | Iterations after the fix | Out-of-range read |
| --- | --- | --- | --- | --- |
| `PS_UIDetect1` | 1 | `(0,0) (1,1) (2,2)` | unchanged | none |
| `PS_UIDetect2` | 4 | `(0,3) (1,4) (2,5)` | unchanged | none |
| `PS_UIDetect3` | 7 | `(0,6) (0,7) (1,8) (2,9)` | unchanged | none |
| `PS_UIDetect4` | 10 | `(0,10) (1,11)` | `(0,10)` | index 11, one past the 11 entries |
| `PS_UIDetect5` | 13 | — | — | no entry, loop never entered |

Those traces assume the checked-in tables (`PIXELNUMBER 11`, UINr 1-10 with UINr 7 on two rows). The
original single-entry default (`PIXELNUMBER 1`, one entry) had the same defect in `PS_UIDetect1`: the
old loop read indices `0` and `1` for a one-element array.

Practical impact is usually nil: the out-of-range read tends to return zeros, and the subsequent
`UIPixelCoord_UINr[uinumber].z == <UINr>` condition then fails and rejects it. It remains genuinely
undefined behaviour, and it is exactly the code path the earlier commits
(`6a5c107 -Fixed incorrect PIXELNUMBER value errors (again >.>)`, which moved this guard from `i` to
`uinumber`) have already had trouble with.

Fix applied — all five loops are now bounded on both counters:

```hlsl
for (int i=0; i < 3 && uinumber < PIXELNUMBER; i++){
```

The `i -= 1` retry is deliberately kept: it re-runs an iteration until every entry sharing one `UINr`
has been consumed, which is how multi-colour detection works. With the extra bound every index
provably stays within `0 .. PIXELNUMBER-1`, and re-running the traces above produces the same number
of iterations and the same matched colours as before — the only behaviour change is that the final
iteration can no longer read past the end of the array.

Verified by simulating the loop body for every UI number across 23 table configurations (1-15 unique
ascending entries, repeated UINrs at the start, middle, end and as the only entry, and the two
checked-in tables): the fixed loop never indexes outside `0 .. PIXELNUMBER-1`, the number of matching
iterations is identical before and after, and the only iterations that disappear are exactly those
that read past the end — one in `PS_UIDetect4` and one in `PS_UIDetect1`, none anywhere else. The
documented multi-colour case (UINr 7 on two consecutive rows) still consumes both rows, 2 matches in
both variants.

The in-loop `if (uinumber == PIXELNUMBER){break;}` would also be unreachable once the loop is bounded,
because the loop condition rejects that index before the body runs; it was accordingly removed from all
five functions as part of 7.3.

## 2. Zero tolerance is a dead state (fixed)

The tolerance sliders allow 0 (`ui_min = 0; ui_max = 255;`, e.g. `Shaders/UIDetectMulti.fx:25-31`),
but detection tests a strict inequality:

```hlsl
if (Every1 == 0 && diff.r < tolerance1.r && diff.g < tolerance1.g && diff.b < tolerance1.b && ...) uiDetected.x = 1;
```

`diff` is non-negative (`abs(pixelColor - uiPixelColor)`), so `diff.r < 0` can never hold. Setting any
tolerance to 0 therefore disables detection for that UI element rather than requesting an exact match.

Fix applied — all fifteen tolerance sliders were raised to `ui_min = 1`:

```hlsl
uniform float3 tolerance1 < __UNIFORM_SLIDER_FLOAT3
	ui_label = "RGB tolerance";
	ui_category = "Mask 1 Tolerances";
	ui_category_closed = true;
	ui_min = 1; ui_max = 255;
	ui_step = 1;
> = 1;
```

The other two options were rejected: changing the comparisons to `<=` would also change behaviour at
`ui_max` (a tolerance of 255 would then match every possible colour difference, whereas `< 255` still
rejects a full white-on-black difference), and leaving the slider at 0 while making `0` mean "exact
match" would keep the control labelled with a value that no longer behaves like a tolerance. Raising
the slider floor keeps the meaning of every displayed value intact and changes nothing for any
existing configuration, since all fifteen defaults are 1.

Not covered by this fix: a tolerance that *is* at its maximum, 255, does match every colour except an
exact opposite (255) difference, so detection becomes effectively unconditional there. That is a
plausible intent for a slider explicitly set to maximum, and it was left alone.

Only the fifteen `toleranceN` sliders were touched. `ui_min = 0; ui_max = 255;` also appears on
`CrossColor` (`Shaders/UIDetectMulti.fx:532-538`), a `__UNIFORM_COLOR_FLOAT3` used purely as a
crosshair colour for the diagnostics overlay; its value is never compared against a distance, so it
is not affected by this defect and was left as is.

## 3. `PS_Antibloom` ignores `UIDM_INVERT` (fixed)

`PS_RestoreColor` honours inverted mode by swapping the two sources
(`Shaders/UIDetectMulti.fx:1086-1092`):

```hlsl
#if (UIDM_INVERT == 0)
    float3 colorOrig = tex2D(ColorBeforeMulti, texcoord).rgb;
    float3 color = tex2D(BackBuffer, texcoord).rgb;
#else
    float3 color = tex2D(ColorBeforeMulti, texcoord).rgb;
    float3 colorOrig = tex2D(BackBuffer, texcoord).rgb;
#endif
```

`PS_Antibloom` (`Shaders/UIDetectMulti.fx:1008-1009`) always uses the non-inverted assignment:

```hlsl
float3 colorOrig = 0;
float3 color = tex2D(BackBuffer, texcoord).rgb;
```

So `UIDM_INVERT = 1` combined with `UIDM_ANTIBLOOM = 1` produced inconsistent compositing between the
two passes.

Fix applied — `PS_Antibloom` now swaps its sources the same way `PS_RestoreColor` does:

```hlsl
		#if (UIDM_INVERT == 0)
			float3 colorOrig = 0;
			float3 color = tex2D(BackBuffer, texcoord).rgb;
		#else
			float3 color = 0;
			float3 colorOrig = tex2D(BackBuffer, texcoord).rgb;
		#endif
```

That reproduces `PS_RestoreColor`'s pairing exactly while keeping `PS_Antibloom`'s own convention for
the black side. `PS_RestoreColor` pulls `colorOrig` from `ColorBeforeMulti` and `color` from the back
buffer in normal mode; `PS_Antibloom` pulls `colorOrig` from a constant black and `color` from the back
buffer. So in normal mode it reads `lerp(0, backBuffer, mask)` unchanged, and in inverted mode it reads
`lerp(backBuffer, 0, mask)`, matching the after-pass.

The two blocks are still separate functions with their own colour sources, but they no longer keep two
more copies of the mask-blend logic: the fifteen `if (uiN.c < FTDn){mask = uiMaskN.c; color =
lerp(colorOrig, color, mask);}` triples in each are now `UIDM_BlendChannel` calls. See section 8.

## 4. Mask assets were blank placeholders (fixed)

Commit `ddf5f58` ("Add files via upload") overwrote the three previously authored masks with five
byte-identical files and added two more, all 1920x1080 and **100% pure white** — i.e. no colour in any
RGB channel anywhere:

```
696aee65a1eac0b861fc57f943ee6e90  Textures/UIDetectMaskRGBMulti.png
696aee65a1eac0b861fc57f943ee6e90  Textures/UIDetectMaskRGBMulti2.png
696aee65a1eac0b861fc57f943ee6e90  Textures/UIDetectMaskRGBMulti3.png
696aee65a1eac0b861fc57f943ee6e90  Textures/UIDetectMaskRGBMulti4.png
696aee65a1eac0b861fc57f943ee6e90  Textures/UIDetectMaskRGBMulti5.png
```

Because the mask is sampled as `mask = uiMask.r/g/b` and then used as a blend factor, an all-white
mask selects the masked content everywhere — the feature silently does nothing. The blobs replaced by
`ddf5f58` were real (e.g. the previous `UIDetectMaskRGBMulti2.png`, `19192` bytes, contained magenta,
yellow and cyan regions).

Fixed in `0629675` by restoring the real 2560x1440 masks for slots 1-4. Verified afterwards by
sampling each configured coordinate in its own channel:

| UINr | Coordinate | RGB value | Mask / channel | Mask value | Meaning |
| --- | --- | --- | --- | --- | --- |
| 1 (health) | (124, 98) | 7, 7, 7 | 1 / r | 0 | protected |
| 2 (menu) | (2378, 81) | 4, 4, 4 | 1 / g | 0 | protected |
| 3 | (0, 0) | 0, 0, 0 | 1 / b | 255 | placeholder row |
| 4 (inventory) | (2436, 849) | 4, 4, 5 | 2 / r | 0 | protected |
| 5, 6 | (0, 0) | 0, 0, 0 | 2 / g, b | 255 | placeholder rows |
| 7 (gestures) | (2010, 269) | 0, 1, 0 | 3 / r | 0 | protected |
| 7 (gestures) | (975, 250) | 216, 1, 20 | 3 / r | 0 | protected, second colour |
| 8, 9 | (0, 0) | 0, 0, 0 | 3 / g, b | 255 | placeholder rows |
| 10 (settings) | (2436, 537) | 0, 1, 0 | 4 / r | 0 | protected |

All coordinates are inside the 2560x1440 bounds, and the placeholder rows correctly land on unprotected
(255) pixels. `UIDetectMaskRGBMulti5.png` is still the 1920x1080 blank placeholder and has no pixel
entries, which is why `UIDM_MASK_COUNT` is 4 and not 5.

## 5. Mask 5 guard and pass referenced the wrong slot (fixed)

Two copy-paste errors affecting slot 5, both fixed in `0b12b4c`:

- The mask 13 uniform block used `#if (UIDM_MASK_COUNT > 3)` instead of `> 4`, exposing mask 13's
  tolerances while mask 5's textures and shaders were compiled out. That is precisely the failure mode
  described in section 1's history: uniforms without their consumers.
- Under `#if (UIDM_MASK_COUNT > 4)`, the technique pass bound `PS_UIDetect4` and `texUIDetectMulti4`
  instead of `PS_UIDetect5` and `texUIDetectMulti5`, so the fifth slot would have written into the
  fourth slot's render target.

Guards and slot numbers now line up for all five slots.

## 6. `README.md` is out of date (fixed)

- It repeatedly told the reader to set `UIDM_EVERYPIXEL`, which no longer exists — the per-element
  `EveryN` uniforms replaced it in `78e0ad1` / `fb35dc3`.
- "For the other 2-14 masks, you just repeat these steps" was a leftover from an earlier layout with
  more slots. There are 5 masks and 15 UI elements.
- It documents the workflow but never mentioned the current `UIDM_MASK_COUNT` range semantics.

Fix applied — the three stale passages were corrected in the document's existing conversational voice,
with no restructuring:

- The `UIDM_EVERYPIXEL` instruction now refers to that ui element's own "Does every pixel needs to be
  showing to activate?" toggle, and notes that it lives in the element's mask Tolerances category and
  is unchecked by default.
- "For the other 2-14 masks" became "For the other masks, 2 through 5", and the paragraph now explains
  that `UIDM_MASK_COUNT` has to be raised to the new mask's number, either in `UIDetectMulti.fxh` or
  straight in the reshade menu next to `UIDM_DIAGNOSTICS`, because higher masks are compiled out.
- The same paragraph, which tells the reader to write as many `float3`/`float4` rows as there are
  captured colour values, now also tells them to raise `PIXELNUMBER` to the total number of entries.
  That step was already implied earlier in the document, but was missing exactly where a reader adding
  multiple colour rows for one ui element would need it.

Still not covered by `README.md`: it never mentions masks 2-5 each being its own PNG file beyond the
naming convention, and it does not describe inverted mode (`UIDM_INVERT`) or anti-bloom
(`UIDM_ANTIBLOOM`) at all. Neither is described inaccurately, so they were left out of this fix rather
than having wording invented for them.

## 7. Minor inconsistencies (partly fixed)

1. *(fixed)* `uniform bool EveryN < __UNIFORM_SLIDER_FLOAT1 ... >` annotated a boolean with a
   float-slider annotation (`Shaders/UIDetectMulti.fx:51-55` and the analogous blocks for all fifteen
   elements). It worked, but the annotation did not describe the value. All fifteen now use
   `__UNIFORM_SLIDER_BOOL1`:

   ```hlsl
   uniform bool Every1 < __UNIFORM_SLIDER_BOOL1
   	ui_label = "Does every pixel needs to be showing to activate?";
   	ui_category = "Mask 1 Tolerances";
   	ui_category_closed = true;
   > = 0;
   ```

   Verified against the installed ReShade 6.8.0 headers
   (`DARK SOULS REMASTERED/reshade-shaders/Shaders/ReShadeUI.fxh`), where `__UNIFORM_SLIDER_BOOL1`
   through `_BOOL4` are the documented boolean variants and are defined as `__UNIFORM_SLIDER_ANY`,
   i.e. `ui_type = "slider"` on ReShade 4.0.1+ — identical to what the `_FLOAT1` variants they
   replaced resolve to. So the widget and the stored value are unchanged; only the macro name now
   matches the declared type.

2. *(fixed)* Naming was inconsistent for slot 1 only: its pixel shaders were `PS_UIDetect` (no
   suffix) and `PS_UIDetectTimer` (no suffix), while its own timer-setup shader and every other slot
   were suffixed. Renamed to `PS_UIDetect1` and `PS_UIDetectTimer1`, together with their two pass
   bindings in technique `UIDetectMulti`. Slot 1's textures and samplers (`texUIDetectMulti`,
   `texUIDetectTimer`, `texUIDetectMaskMulti` and their samplers) were deliberately left unchanged, as
   was the `UIDetectTimer` sampler that `PS_UIDetect1` reads: the rename therefore did not touch a
   single texture lookup, which keeps a purely cosmetic change from altering rendering behaviour. The
   three technique names (`UIDetectSetup`, `UIDetectMulti_Before`, `UIDetectMulti_After`) and the
   `UIDetectMulti` technique are user-visible in ReShade and named in `README.md`, so they keep their
   names as well.

   *(completed)* The textures and samplers were suffixed later, in the section 8 refactor, finishing
   what this finding started. Slot 1's buffers are now `texUIDetectMulti1`, `texUIDetectTimer1`,
   `texUIDetectMaskMulti1` and `UIDetectMulti1`, `UIDetectTimer1`, `UIDetectMaskMulti1`, so every slot
   is spelled identically and the slot macros need no special case. Three things make that safe:
   - **No preset is invalidated.** The real preset (`ReShadePreset.ini`) persists only the uniforms
     (`toleranceN`, `FAN`, `FDN`, `EveryN`, `BlackFont`, `CrossColor`, `fPixelPosX/Y`,
     `PreprocessorDefinitions`) and keys on technique and `.fx` file names; no texture or sampler name
     is ever stored. A `grep` across every `.ini` in the game directory finds none. The preset's
     anchors — the three technique names, `UIDetectSetup` and `UIDetectMulti.fx` — are unchanged.
   - **No mask file is renamed.** The `source=` PNG filenames are untouched
     (`UIDETECTMASKRGBMULTI.png`, `…2..5.png`), so a user's authored mask keeps loading.
   - **Rendering is unaffected**, verified by compiling before and after: identical instruction counts
     and opcode histograms. `texColorBeforeMulti` / `ColorBeforeMulti` are slot-agnostic and were
     correctly left unsuffixed.
3. *(fixed)* The `if (uinumber == PIXELNUMBER){break;}` immediately after the pixel comparisons was
   dead in all five functions: the loop already conditions on `uinumber < PIXELNUMBER`, so the index
   can never reach `PIXELNUMBER` inside the body. It was removed from all five. `PS_UIDetect1` had a
   second dead guard of the same kind in its entry-search loop, `if (i == PIXELNUMBER){break;}` inside
   `for (int i=0; i < PIXELNUMBER; i++)`; that one was removed as well, which also makes the five
   entry-search loops uniform. `PS_UIDetect5` turned out never to have had the second guard, so the
   count was five pixel-comparison guards plus four entry-search guards, not ten.
4. *(fixed)* `State_Pixel_Color` drew its readout at hard-coded pixel positions, so the diagnostic text
   shifted with resolution. `DrawText_String`'s `pos` and `size` arguments are absolute render-target
   pixels — the macro computes `uv = (tex * float2(BUFFER_WIDTH, BUFFER_HEIGHT) - pos) / size` — so the
   readout sat at 42% across a 1920-wide buffer but 31% of 2560 and 21% of 3840, with the glyphs
   shrinking accordingly, and vanished entirely below an 800 px wide or ~170 px tall buffer. The layout
   was authored for 1080p, so it is now scaled by the vertical resolution:

   ```hlsl
   float uiScale = BUFFER_HEIGHT / 1080.0;
   float2 textPos = float2(800.0, 100.0) * uiScale;
   float textSize = 50.0 * uiScale;
   float textStep = 34.0 * uiScale;
   ```

   with the three calls moved to `textPos`, `textPos + float2(0.0, textStep)` and
   `textPos + float2(0.0, textStep * 2.0)`. Scaling by `BUFFER_HEIGHT` rather than width keeps the
   glyph cell (`size` spans the vertical axis) proportional in both directions, and the original 34 px
   line advance was scaled rather than switched to `DrawText_Shift`, which advances by a full `size`
   (50 px) and would have changed the shipped line spacing.
5. *(reclassified — not a defect)* The mask textures are declared `Format=RGBA8` while the shipped mask
   images have no alpha channel. Investigated and withdrawn: `RGBA8` is the correct and only possible
   declaration, and the shader never reads mask alpha. Full reasoning in the Not defects section
   below.
6. *(fixed)* `State_Pixel_Color` declared `float res;` without a value and then used it as the
   accumulator that `DrawText_String` performs `output += text;` on, before `return res;`. Every pixel
   of the pass therefore read an uninitialised variable, so the pass was formally undefined at every
   pixel it wrote — outside the glyphs, where `text` is 0, it returned whatever happened to be in the
   register. It worked only because the compiler started the register at zero. Fixed as
   `float res = 0.0;`, in the same edit as 7.4.

## 8. Five slots and fifteen elements were written out by hand (fixed)

`UIDetectMulti.fx` was 1296 lines, and most of it was the same code repeated once per slot or once
per UI element: fifteen uniform blocks of four annotated sliders each, five near-identical
`PS_UIDetectN` detect loops, two blend bodies carrying fifteen near-identical `if (uiN.c < FTDn)`
lines each, five texture/sampler groups, ten trivial timer shaders and 24 pass blocks. Per
`AGENTS.md` a new mask slot touched eight places, and finding 5 was exactly the bug that produces.

The refactor keeps the semantics and removes the repetition, in two halves:

- **Runtime logic → helper functions**, so it stays steppable and greppable. `UIDM_DetectChannels`
  replaces the five detect loops; `UIDM_BlendChannel` replaces the fifteen blend lines in each of
  `PS_Antibloom` and `PS_RestoreColor`. HLSL inlines both, so they cost no call.
- **Declarations → macros**, which nothing else can deduplicate: each uniform needs its own
  identifier and category for ReShade's UI. `UIDM_ELEM(e)` emits one element's four uniforms,
  `UIDM_SLOT(n, png)` one slot's textures and samplers, `UIDM_TIMER_SHADERS(n, …)` its two timer
  shaders, and `UIDM_TIMER_PASS(n)` / `UIDM_DETECT_PASS(n)` its three passes.

The file is now 641 lines. Uniform names, defaults, category strings, technique names, pass wiring
and PNG filenames are all unchanged, so no preset and no mask file is affected.

### Two HLSL constraints worth knowing before trying a tidier design

1. **An effect `sampler` or `texture2D` cannot be initialised from another one**, so the obvious
   data-driven design — arrays of samplers indexed by slot — does not compile at all. `fxc` rejects it
   with `error X3011: 'sArr': initial value must be a literal expression`. Shared functions are the
   only way to collapse the runtime logic.
2. **A preprocessor directive cannot appear inside a macro body.** `#define X \ #if … \ #endif`
   produces `error X3000: syntax error: unexpected string constant`. The `UIDM_MASK_COUNT` guards are
   therefore still written out around every macro invocation.

A third, milder one: a macro cannot expand an *annotation key*, so `source=UIDM_STR(png)` works only
because the preprocessor substitutes the macro inside the attribute.

### Verified neutrality

The change was checked by compiling every pixel shader with `fxc` (Windows Kits 10.0.26100.0) before
and after, across `UIDM_MASK_COUNT` 1-5 and the default, `UIDM_ANTIBLOOM=1`, `UIDM_DIAGNOSTICS=1` and
`UIDM_INVERT=1` variants — 250 shaders, driven by `tools/verify_shaders.py`.

| Shader | Before | After | Result |
| --- | --- | --- | --- |
| `PS_UIDetect1` | 86 | 86 | identical instructions, rescheduled |
| `PS_UIDetect2` | 82 | 82 | identical instructions, rescheduled |
| `PS_UIDetect3` | 96 | 96 | identical instructions, rescheduled |
| `PS_UIDetect4` | 43 | 43 | identical instructions, rescheduled |
| `PS_UIDetect5` | 4 | 4 | byte-identical |
| `PS_Antibloom` | 83 | 83 | identical instructions, rescheduled |
| `PS_RestoreColor` | 96 | 96 | identical instructions, rescheduled |
| `PS_UIDetectTimer1` | 4 | 4 | identical instructions, rescheduled |
| `PS_UIDetectTimer2-5` | 4 | 4 | byte-identical |
| `PS_UIDetectTimerSetup1-5` | 6 | 6 | byte-identical |

Every shader keeps its exact instruction count and opcode histogram. 149 of the 250 comparisons are
byte-identical outright; 101 share an identical instruction stream but are scheduled differently.
The 101 are exactly the nine shaders that read the pixel table or blend the masks —
`PS_UIDetect1-4` (20, 16, 12 and 8 comparisons respectively, since the guards remove them at low mask
counts), `PS_RestoreColor` (20), `PS_Antibloom` (5, the anti-bloom variant), `PS_UIDetectTimer1` (20)
and the four `PS_UIDetectTimer2-5` cases where the texture lookup reshapes — a compiler response to
the source being reshaped, not a behavioural difference.

Because instruction counts alone cannot *prove* it, the detect loop was also checked at the source
level: taking `HEAD`'s `PS_UIDetect1` body and applying only the transforms the refactor claims (slot
number → `base`/`base + 1`/`base + 2`, `EveryN` → `every.x/y/z`, `toleranceN` → `toleranceR/G/B` on
three separate parameters, `FTAn` → `FTA.x/y/z`, `float3(Every1, Every2, Every3)` → `every`)
reproduces `UIDM_DetectChannels`' body exactly, as a 767-token stream on both sides.

This also settles the performance question. The duplication cost nothing at runtime, so removing it
wins and loses nothing. The lever that does matter is `UIDM_MASK_COUNT`, measured per pixel:

| `UIDM_MASK_COUNT` | `PS_RestoreColor` | `PS_Antibloom` |
| --- | --- | --- |
| 1 | 27 | 23 |
| 2 | 50 | 43 |
| 3 | 73 | 63 |
| 4 | 96 | 83 |
| 5 | 119 | 103 |

Each extra slot costs about 23 instructions in `PS_RestoreColor` and 20 in `PS_Antibloom` at full
resolution. The shipped configuration is `UIDM_MASK_COUNT 4` while `UIDetectMaskRGBMulti5.png` is an
unused placeholder with no pixel entries, so slot 5 is compiled, costs its instructions, and detects
nothing. Reducing `UIDM_MASK_COUNT` and leaving `UIDM_ANTIBLOOM = 0` (worth about 3x on
`UIDetectMulti_Before`) are the real wins.

### One caught mistake, and one that got away

The first version of `UIDM_DetectChannels` took a single `tolerance` and applied it to all three
elements. That is wrong — `tolerance1`, `tolerance2`, `tolerance3` are three independent uniforms, one
per element and mask channel. The check caught it immediately, as a drop from 82 to 80 instructions in
`PS_UIDetect2` and 96 to 94 in `PS_UIDetect3`, because `fxc` began commoning up a single uniform where
three were read. A silent per-element behaviour change would have shipped otherwise.

Worth recording too: the verification harness itself initially reported a confident pass while being
wrong three times over — it never passed `/Fo`, so there was no bytecode to hash and every shader
compared as equal; its entry-point regex was line-anchored, so the macro-generated timer shaders were
silently skipped; and its instruction histogram was never cross-checked against `fxc`'s own count. All
three turned a missing measurement into a success. It now fails loudly on absent data, and cross-checks
the histogram, precisely because of this.

## Not defects

- `Shaders/Reshade overall effect.fx` is a self-contained before/after blend helper; nothing in it
  depends on `UIDetectMulti` state.
- **The mask textures being `Format=RGBA8` for images with no alpha channel.** Originally recorded as
  finding 7.5, withdrawn after investigation.

  `Format` only accepts the formats ReShade defines. The full list, extracted from the installed
  `dxgi.dll`: `R8`, `RG8`, `RGBA8`, `R16`, `RG16`, `RGBA16`, `R16F`, `RG16F`, `RGBA16F`, `R32F`,
  `RG32F`, `RGBA32F`, `RGB10A2`. There is **no `RGB8`** and no 24-bit format, so a three-channel mask
  image can only ever land in an `RGBA8` texture with the fourth channel padded. The sibling
  `UIMask.fx` handles the same problem the same way, declaring `R8` when it uses one channel and
  `RGBA8` when it uses all three (`#define TEXFORMAT` at `UIMask.fx:105-109`).

  The alpha channel is also never read: all five mask lookups in `PS_RestoreColor` and `PS_Antibloom`
  are `.rgb`, and masking is driven by the red/green/blue value alone (`mask = uiMask.r`, where 0
  means protected), so alpha was never part of the design.

  For the record, the colour types involved:

  | Image | Colour type | Alpha in file | Alpha carries information |
  | --- | --- | --- | --- |
  | Original mask, before `ddf5f58` | 6 — RGBA8 | yes | **no** — all 2073600 pixels are alpha 255 |
  | Blank placeholders from `ddf5f58` | 2 — RGB | no | no |
  | Current masks 1-4 | 3 — palette, 4/4/1/4-bit, no `tRNS` | no | no |
  | `UIDetectMaskRGBMulti5.png` | 2 — RGB | no | no |

  So the masks were not originally RGBA-with-meaningful-alpha either; the one RGBA file the repository
  ever held had a completely uniform alpha channel. The only residue is that a user who authors a mask
  with deliberately soft, semi-transparent edges will find that ignored, which is why `README.md` now
  tells the reader to make mask edges hard or blurred instead.
- `UIDetectSetup` being `hidden = true; timeout = 1` is intentional: the 1x1 timer textures must be
  initialised once with `1 - EveryN` so that a mask starts in the correct state before the first
  detection frame.
- `#undef BUFFER_PIXEL_SIZE` / redefinition in `Shaders/UIDetectMulti.fx:19-20` is a deliberate
  compatibility shim for older `ReShade.fxh` versions.
