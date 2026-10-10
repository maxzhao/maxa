# Storyboard Video Seed

Use for 4/6/9-panel storyboards, comic drama, short-video visual seeds, news visualization, and I2V references. Inspired by 9-panel storyboard workflows as video-model visual DNA; keep structure and pitfalls only, not copied prompts.

## Use Cases

- Visual seed for short video, ad, music video, or film fragment.
- 4/6/9-panel storyboard, comic drama board, news event visualization.
- Multi-shot plan requiring consistent character, costume, and scene.
- Unified character/scene reference for I2V models, not direct motion prompt.

Shared image generation/editing techniques are owned by `references/craft.md`; the schema and example below are optional domain briefs. Use `references/preflight.md` for runtime-dependent request settings and exact-size handling, separately from visual prompt text.

## Mini Schema

```text
Create a [4/6/9]-panel storyboard on one canvas for [story/use_case].
Canvas: [landscape/square], all panels in a clean grid.
Story purpose: [video seed / comic drama / news visualization / ad storyboard].
Shared visual DNA: [main character identity], [wardrobe], [location], [palette], [time of day].
Panel list: Panel 1 [shot/action], Panel 2 [shot/action], ...
Camera language: [wide shot / close-up / over-shoulder / insert / reveal].
Labels: [exact supplied dialogue/captions, or panel numbers only when no copy is requested].
Constraints: same character across panels, consistent costume and setting, storyboard as visual reference for I2V, not a filmed comic page.
```

## Required Controls

- Panel count and layout: 4, 6, or 9 panels; all panels on one canvas.
- Character consistency: name/identity, costume, hair, key props, proportions, style.
- Scene consistency: place, time, weather, color, lighting.
- Per-panel shot/action: shot size, action, emotion, composition.
- Purpose: I2V visual seed / visual DNA, not final motion prompt.

## Recommended Sizes

- 9-panel square storyboard: `2048x2048`.
- Landscape 6/9-panel board: `1536x1024` or `2048x1152`.
- Portrait short-video seed: `1024x1536` or `2160x3840`.
- Low-complexity sketch: `1536x1024`.

## Pitfalls

- A shared canvas can help continuity; verify each panel. For separate scenes, reuse an approved character reference and repeat defining appearance constraints.
- Do not write motion prompt as a “filmed comic page”; storyboard is visual DNA for later I2V prompting.
- Use panel numbers when no other copy is requested. Preserve supplied dialogue and captions, assign each to a panel, and check spelling and placement instead of deleting speech bubbles automatically.
- State shared invariants: outfit, hair, props, face shape, color, lighting.
- News visualization should stay neutral and factual; avoid unprovided identity details or inflammatory symbols.

## Visual Verification

- Check panel count, grid layout, order, and numbering.
- Check character/costume/prop/scene/color consistency across panels and clear action/camera variation.
- Check for excessive speech bubbles, long captions, or unreadable text.
- Check suitability as I2V visual DNA instead of chaotic comic page.

## Prompt Skeleton

```text
Create a square nine-panel storyboard on one canvas as a visual seed for a 30-second product launch video.
Shared visual DNA: the same young product designer wearing a cream jacket and round glasses, working in a warm studio at dusk, teal and amber color palette, realistic cinematic sketch style.
Layout: 3x3 clean grid with thin gutters, panel numbers only.
Panel 1: wide shot, designer enters the studio with a laptop.
Panel 2: close-up, hands open a prototype app on screen.
Panel 3: over-shoulder shot, dashboard lights up.
Panel 4: medium shot, designer sketches on glass wall.
Panel 5: insert shot, sticky notes and metrics connect.
Panel 6: close-up, surprised smile.
Panel 7: wide shot, team gathers around the screen.
Panel 8: hero shot, product UI reflected on glasses.
Panel 9: final wide shot, studio window with city lights.
Keep the same character, wardrobe, studio, palette, and visual style across all panels. Treat the storyboard as visual DNA for an image-to-video model, not as a final motion prompt. Avoid speech bubbles and unreadable captions.
```
