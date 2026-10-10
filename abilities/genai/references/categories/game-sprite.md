# Game Sprite and Sprite Sheet

Use for game character sprites, sprite sheets, animation frames, pixel-art characters, RPG/fighter/platformer sprites, and frame-consistent game animation references. Inspired by SpriteForge-style prompt factories; this file stores rewritten control rules only, not copied source prompts.

## Use Cases

- Single character sprite or style preview.
- Sprite sheet with idle, walk, jump, attack, hurt, knockout, or turn-around frames.
- One animation frame in a sequence, using previous/next frame context.
- Pixel-art, retro, arcade fighter, cozy RPG, cel-shaded, hand-drawn, or flat vector game characters.
- Reference for later manual sprite refinement and game-engine import.

Shared image generation/editing techniques are owned by `references/craft.md`; the schemas below are optional domain briefs. Use `references/preflight.md` for runtime-dependent request settings and exact-size handling, separately from visual prompt text.

## Mini Schema

```text
Create a game character sprite [single frame / sprite sheet / animation frame] for [character].
Style family: [pixel art / cozy RPG / arcade fighter / cel-shaded adventure / hand-drawn gothic / flat cartoon vector].
Canvas: [single sprite / sheet grid], [resolution], [frame count], [gutter/spacing].
Action: [idle / walk / jump / punch / air attack / hurt / knockout / turn around].
Frame context: frame [index] of [total], previous pose [summary], next pose [summary], smooth motion progression.
Character invariants: [silhouette, palette, costume, proportions, outline thickness, weapon/prop].
Rendering rules: [palette limit, outline, shading, anti-aliasing/dithering, pixel edge policy].
Background policy: isolated sprite on a simple unobtrusive backdrop; no scenery, no UI, no text, no logo.
Constraints: consistent proportions, readable silhouette, game-ready pose, no extra limbs, no random props.
```

## Style Families

Use generic style anchors; do not copy protected game/IP names into final prompts unless the user explicitly provides a lawful reference.

| Style family | Prompt anchor |
|---|---|
| Cozy farming RPG pixel sprite | 32x32 or 48x48 readable pixel-art character, warm palette, simple silhouette, clean tile-game readability |
| Retro 8-bit sprite | low-color 8-bit character, hard pixel edges, no anti-aliasing, simple animation readability |
| 16-bit adventure RPG sprite | richer pixel palette, compact body proportions, clear outline, top-down or side-view game readability |
| Arcade fighter sprite | bold anatomy, strong pose, dramatic clean outline, punchy shading, readable silhouette |
| Cel-shaded adventure sprite | clean flat color, readable cartoon proportions, crisp contour, game-character turnaround feel |
| Anime game sprite | stylized face/hair, cel-shaded costume shapes, bright controlled palette, readable silhouette |
| Hand-drawn gothic sprite | ink-like contour, dark whimsical palette, compact game silhouette, atmospheric but isolated |
| Bouncy cartoon sprite | rounded shapes, squash-and-stretch pose, strong expression, simple colors |
| Flat vector game sprite | clean vector-like shapes, minimal shading, smooth readable silhouette |

## Required Controls

- Character role, body type, costume, palette, and key props.
- View direction: side-view, front-view, three-quarter, top-down, or isometric.
- Sprite mode: single frame, sprite sheet, or one animation frame.
- Action and animation phase: idle, walk, jump, attack, hurt, knockout, turn around; frame index if applicable.
- Resolution or intended sprite scale; frame grid and gutter for sprite sheets.
- Rendering constraints: outline thickness, palette limit, shading, anti-aliasing/dithering policy.
- Invariants across frames: silhouette, proportions, costume, color palette, weapon/prop, outline thickness.
- Background policy: state the intended visible backdrop or isolation requirement in prompt prose; keep request settings outside the prompt.

## Recommended Sizes

- Single sprite / style preview: `1024x1024`; prompt can state intended in-game sprite scale such as 32x32, 48x48, 64x64, or 128x128.
- Sprite sheet concept: `2048x2048` or `1536x1024`.
- Fighter stance / large character sheet: `2048x2048` or `1536x1024`.
- Portrait-style game character concept that will later become sprite: `1024x1536`.

## Prompt Construction Rules

- Put game/sprite deliverable first: “Create a game-ready isolated sprite sheet ...”.
- Specify sprite scale separately from output image size; generated image canvas is larger than final pixel asset.
- For sprite sheets, specify grid, frame count, action per frame, and gutter/spacing.
- For animation-frame continuation, state previous frame, current frame, next frame, and invariants.
- Use strong negative boundaries: no scenery, no UI, no text, no watermark, no random props, no extra characters.

## Pitfalls

- Do not ask for a full illustration when the user needs a sprite; keep isolated silhouette and game readability.
- Do not mix too many style families in one prompt.
- Do not make every frame a new character; repeat invariants explicitly.
- Do not pass `n`; generate multiple candidates through independent calls.
- Validate grid registration, silhouette, frame count, and separation. Pixel-identical retained regions require deterministic compositing rather than prompt guarantees.
- Avoid naming protected game franchises as direct style targets; use generic visual anchors.

## Visual Verification

- Check whether the output is isolated and sprite-like, not a poster/scene.
- Check action readability and silhouette at a small scale.
- For sheets, check frame count, grid order, gutter separation, and no merged frames.
- Check character invariants across frames: palette, outfit, proportions, outline, prop.
- Check absence of text, UI, watermark, random background, extra characters, and accidental logos.

## Prompt Skeleton: Single Sprite

```text
Create a game-ready isolated character sprite concept for a cheerful forest courier.
Style family: cozy farming RPG pixel-art sprite, intended in-game scale 48x48 pixels, shown enlarged on the generated canvas.
View: three-quarter front view, compact readable silhouette.
Character invariants: moss-green hooded cloak, cream tunic, small leather satchel, brass map tube, warm brown boots, leaf-shaped pin.
Rendering rules: limited warm palette, clean 1-2 pixel dark outline, simple cel-like pixel shading, crisp pixel edges, readable at small size.
Background policy: isolated sprite on a simple plain backdrop, clean silhouette, no scenery, no UI, no text, no logo.
Constraints: game-ready pose, no extra limbs, no random props, no complex illustration background.
```

## Prompt Skeleton: Sprite Sheet

```text
Create a game-ready sprite sheet concept for a bouncy cartoon slime knight.
Style family: 16-bit side-view platformer sprite with clean pixel edges and a bright limited palette.
Canvas: square sheet, 4x2 grid, clear gutters between frames.
Actions: frame 1 idle, frames 2-5 walk cycle, frame 6 jump anticipation, frame 7 mid-air slash, frame 8 hurt recoil.
Character invariants: same round slime body, tiny helmet, short wooden sword, teal body color, silver helmet, black 1-2 pixel outline.
Rendering rules: consistent proportions, readable silhouette, simple shading, no anti-aliased blur, no merged frames.
Background policy: simple plain backdrop, no scenery, no UI, no text, no logo.
```

## Prompt Skeleton: Continuation Frame

```text
Create one isolated game animation frame for the same arcade fighter character.
Style family: bold arcade fighter sprite, clean outline, punchy cel shading, side-view stance.
Frame context: frame 3 of 6 in a forward punch animation. Previous frame: torso twists forward and rear fist begins extending. Current frame: fist reaches full extension, front foot planted, shoulders compressed. Next frame: recoil begins and fist starts returning.
Preserve invariants: same red jacket, black gloves, gold belt, muscular proportions, short dark hair, 2-3 pixel dark outline, same palette.
Background policy: isolated sprite on a simple plain backdrop; no arena, no UI, no text, no logo.
Constraints: smooth motion progression, readable silhouette, no identity drift, no extra limbs, no random props.
```
