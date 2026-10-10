# Poster and Typography

Use for posters, covers, event visuals, brand campaigns, Chinese title designs, and typography-led visuals. Core controls: text hierarchy and first-glance impact.

Shared image generation/editing techniques are owned by `references/craft.md`; the schema and example below are optional domain briefs. Use `references/preflight.md` for runtime-dependent request settings and exact-size handling, separately from visual prompt text.

## Mini Schema

```text
Design a [poster/cover/banner] for [event/product/theme].
Canvas: [3:4/portrait/square/16:9].
Hierarchy: hero title, subtitle, supporting details, fine print.
Exact readable text: "..." / "..." / "...".
Visual anchor: [subject or symbol].
Style: [editorial magazine / Swiss grid / cinematic / packaging / festival].
Palette/material/lighting: [...].
Constraints: crisp typography, strong hierarchy, no garbled Chinese, no fake sponsor logos.
```

## Three-Glance Test

- First glance: main title and hero visual.
- Second glance: subtitle, selling point, date/price/CTA.
- Third glance: texture, background detail, small tags, mood.

Use this domain heuristic to clarify hierarchy when relevant; it is not required prompt syntax.

## Required Controls

- Canvas ratio: plan portrait concepts with `1024x1536` or `2160x3840`; preserve a specified ratio or exact size and resolve custom dimensions through `references/preflight.md`.
- Main title: quoted exact text.
- Subtitle/date/location/price/button: exact supplied copy; use concise phrases only when authoring new copy.
- Layout: centered hero, asymmetrical grid, magazine cover, event poster.
- Type feel: bold sans-serif, serif editorial, brush calligraphy, etc.

## Pitfalls

- Chinese text must be exact readable text.
- Preserve required fine print and supporting copy. Repair typography, contrast, and spacing rather than removing or shortening text automatically.
- No random sponsor logos unless user provided names.
- For commercial posters, specify brand/product/selling points; do not just request “premium”.

## Prompt Skeleton

```text
Design a 3:4 vertical tea brand poster.
Hierarchy: large hero title at the top, product subtitle below, price line near the bottom, small seasonal note.
Exact readable title/copy: "MOUNTAIN TEA" / "COLD BREW SERIES" / "MEDIUM $4" / "LARGE $5" / "SUMMER LIMITED".
Visual anchor: a clear glass cup of cold-brew tea with ice, tea leaves, and mountain mist silhouette.
Style: refined editorial Chinese packaging poster, warm ivory background, deep green typography, subtle rice-paper texture, soft natural light.
Constraints: crisp Chinese typography, strong visual hierarchy, generous spacing, no garbled characters, no fake sponsor logos, no unreadable microtext.
```
