# Brand Logo

Use for logo concept grids, brand identity boards, touchpoint boards, app icons, wordmarks, marks, and lockups. Inspired by logo/brand identity workflows; keep structure and pitfalls only, not copied prompts.

## Use Cases

- Logo exploration: mark, wordmark, monogram, lockup.
- Brand identity board: palette, type direction, logo usage, visual language.
- App/product icon or favicon concept.
- Touchpoint board: business card, packaging, social avatar, launch screen, website hero.
- Multi-direction logo concept grid for later vectorization.

Shared image generation/editing techniques are owned by `references/craft.md`; the schema and example below are optional domain briefs. Use `references/preflight.md` for runtime-dependent request settings and exact-size handling, separately from visual prompt text.

## Mini Schema

```text
Create a brand identity concept for a fictional brand named "[brand_name]".
Deliverable: [logo concept grid / identity board / app icon / wordmark / lockup / touchpoint board].
Brand domain: [industry], audience: [audience], personality: [3 traits].
Core symbol: [abstract mark idea], typography direction: [wordmark style].
Palette: [primary color], [secondary], [neutral], palette-first.
Canvas: [white background / square board / app icon grid].
Use cases: [app icon, website, packaging, social avatar].
Constraints: simple mark, no complex illustration, no fake certification marks, raster concept only if vector is needed later.
```

## Required Controls

- Brand name, industry, audience, personality.
- Deliverable type: logo concept grid, identity board, app icon, wordmark, mark, lockup.
- Palette-first: primary, secondary, neutral before decoration.
- Logo type: wordmark, mark, monogram, lockup, app icon.
- Later use: white background, dark inverse, social avatar, packaging, app icon.

## Recommended Sizes

- Logo concept grid: `1024x1024` or `2048x2048`.
- Brand identity board: `2048x2048` or `1536x1024`.
- App icon concept: `1024x1024`.
- Landscape touchpoint board: `1536x1024` or `2048x1152`.

## Pitfalls

- Logo is not complex illustration; prefer simple, scalable, white-background, strong silhouette.
- No fake logo variants, certification marks, medals, platform badges, or trademark symbols.
- Spell brand name exactly; repair failed lettering with the exact quoted wording and placement. Do not drop a required wordmark; use deterministic typesetting if exact lettering remains unmet.
- If editable vector is required, state raster image is concept exploration and SVG/vector needs another tool.
- Avoid existing brand/IP resemblance; request fictional brand and original abstract mark.

## Visual Verification

- Check brand/wordmark spelling against the supplied copy; a mark-only concept does not satisfy a required wordmark.
- Check mark simplicity, scalability, and white-background readability.
- Check for fake certifications, platform badges, trademarks, random letters, or existing-brand resemblance.
- State raster concept vs final SVG/vector boundary.

## Prompt Skeleton

```text
Create a square brand logo concept grid for a fictional productivity app named "Northstar".
Deliverable: six simple logo concepts on a white background, arranged in a clean 2x3 grid.
Brand domain: personal planning and focus. Audience: founders and creative teams. Personality: calm, precise, optimistic.
Explore original abstract marks based on a compass star, a small path, and a focused dot. Include the exact wordmark "Northstar" below each concept in clean geometric sans typography.
Palette-first: deep indigo, soft sky blue, warm off-white, and one amber accent. Keep marks simple, flat, scalable, and suitable for app icon adaptation.
Avoid complex illustration, fake certification marks, random extra letters, existing brand resemblance, and decorative clutter. Treat this as raster concept exploration; final SVG/vector should be created separately.
```
