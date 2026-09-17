# Code review — UIDetectMulti shader pack

Reviewed revision: `0629675`
Date: 2026-09-17

Scope: `Shaders/UIDetectMulti.fx`, `Shaders/UIDetectMulti.fxh`,
`Shaders/Reshade overall effect.fx`, `Textures/UIDetectMaskRGBMulti*.png`, `README.md`.

Method: line-by-line reading of the HLSL, a simulation of the `PS_UIDetectN` indexing logic against
the checked-in `PIXELNUMBER` / `UIPixelCoord_UINr` tables, and a decode of every mask PNG (zlib
inflate plus PNG scanline unfiltering) to sample the configured coordinates in their own channel. No
runtime verification was possible: the shaders only compile inside ReShade in-game.

## Summary

| # | Finding | Severity | Status |
| --- | --- | --- | --- |
| 1 | Out-of-bounds array read in every `PS_UIDetectN` inner loop | Latent, undefined behaviour | Fixed |
| 2 | A tolerance of 0 makes its UI element permanently undetectable | Minor, latent | Fixed |
| 3 | `PS_Antibloom` ignores `UIDM_INVERT`, unlike `PS_RestoreColor` | Minor | Fixed |
| 4 | All shipped mask PNGs were blank white placeholders | Blocking for the feature | Fixed |
| 5 | Mask 5 uniform guard and technique pass referenced the wrong slot | Functional bug | Fixed |
| 6 | `README.md` describes features and a mask count that no longer exist | Documentation | Fixed |
| 7 | Misc annotation, naming and dead-code inconsistencies | Cosmetic | Partly fixed — 7.1-7.4 and 7.6 done |

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

The two blocks are still near-identical copies of the same mask-blend logic, so any further change to
one must be mirrored in the other. Extracting a shared helper is not possible without restructuring:
the two functions differ in whether the black side comes from a texture or a constant.

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
5. `texture texUIDetectMaskMulti <source="UIDETECTMASKRGBMULTI.png">` is declared
   `Format=RGBA8` while the shipped images are paletted RGB PNGs; harmless, but the alpha channel of
   any user-supplied mask is silently ignored.
6. *(fixed)* `State_Pixel_Color` declared `float res;` without a value and then used it as the
   accumulator that `DrawText_String` performs `output += text;` on, before `return res;`. Every pixel
   of the pass therefore read an uninitialised variable, so the pass was formally undefined at every
   pixel it wrote — outside the glyphs, where `text` is 0, it returned whatever happened to be in the
   register. It worked only because the compiler started the register at zero. Fixed as
   `float res = 0.0;`, in the same edit as 7.4.

## Not defects

- `Shaders/Reshade overall effect.fx` is a self-contained before/after blend helper; nothing in it
  depends on `UIDetectMulti` state.
- `UIDetectSetup` being `hidden = true; timeout = 1` is intentional: the 1x1 timer textures must be
  initialised once with `1 - EveryN` so that a mask starts in the correct state before the first
  detection frame.
- `#undef BUFFER_PIXEL_SIZE` / redefinition in `Shaders/UIDetectMulti.fx:19-20` is a deliberate
  compatibility shim for older `ReShade.fxh` versions.
