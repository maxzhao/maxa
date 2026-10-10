# GenAI Executable Templates Reference

`templates/` is the optional Prompt-as-Code layer for production, repeatable, variable-driven, or preflight-heavy tasks. One-off generation/editing still starts with `references/craft.md` and the category selected by `references/gallery-index.md`.

## Workflow

1. Decide whether a template is needed: App Store screenshot, scientific figure, pitch slide, logo grid, storyboard, game sprite, ecommerce hero, or similar reusable deliverable.
2. Read `references/template-routing.md`; choose one YAML template.
3. Collect/infer `required_inputs`; ask when missing facts affect brand/text/data correctness.
4. Apply `references/craft.md`; render applicable `prompt_schema` fields into a maintainable prompt. Natural language or a concise structured brief is valid; do not send internal template metadata, invented content or empty variables.
5. Check `provider_constraints` + `references/preflight.md`.
6. Call genai; verify with `visual_verify`; for `image_edit`, also apply `references/image-edit-review-standard.md` so normal generative redraw is accepted unless first-glance identity or a named strict invariant fails; repair once at most by default using `failure_repair`.

## Template Fields

Required fields:

- `id`: stable template ID.
- `category`: matching category slug.
- `description`: purpose.
- `source_inspiration`: source name/idea only; no copied external prompt.
- `recommended_requested_size`: upstream size request (`auto` or positive-integer `WIDTHxHEIGHT`); saved dimensions must be verified.
- `required_inputs`, `optional_inputs`: variable contract.
- `prompt_schema`: prompt skeleton.
- `provider_constraints`: call-planning metadata routed through `references/preflight.md`; not model-visible prompt text or a separate model-capability authority.
- `visual_verify`: post-generation checks.
- `failure_repair`: controlled repair strategy.

## Current Templates

| Template | Category | Purpose |
|---|---|---|
| `appstore/screenshot_set.yml` | `app-store-screenshot` | App Store / Google Play upload screenshots |
| `science/research_pipeline.yml` | `scientific-figure` | Research pipeline / method figure sketch |
| `presentation/pitch_slide.yml` | `presentation-slide` | Pitch deck single slide or cover |
| `brand/logo_concept_grid.yml` | `brand-logo` | Logo concept grid and brand direction |
| `storyboard/nine_panel_video_seed.yml` | `storyboard-video-seed` | 9-panel I2V visual DNA storyboard |
| `game/sprite_animation_frame.yml` | `game-sprite` | Game character sprite, sprite sheet, or animation frame |
| `ecommerce/product_hero.yml` | `product` | Ecommerce product hero / main image |
| `uiux/mobile_app_mockup.yml` | `ui-ux` | Mobile app high-fidelity mockup |
| `uiux/desktop_dashboard.yml` | `ui-ux` | Desktop dashboard / Web app data UI |
| `infographic/technical_architecture.yml` | `infographic` | Technical architecture / system pipeline diagram |
| `poster/typography_poster.yml` | `poster-typography` | Typography-led poster with exact title |
| `poster/event_poster.yml` | `poster-typography` | Event / campaign / launch poster |
| `photography/product_photography.yml` | `photography` | Photorealistic commercial product photography |
| `character/character_sheet.yml` | `character` | Character sheet / design board |
| `edit/reference_restyle.yml` | `edit-reference` | Reference restyle / invariant-preserving edit |

## Maintenance Rules

- Do not copy external prompt text; store rewritten schema, variables, constraints, verification, and repair rules.
- Keep example copy short, replaceable, and free of real brands/IP.
- Use `references/craft.md` as the single shared prompt owner and `references/preflight.md` for parameters. Do not promise guaranteed masked/pixel-identical edits, editable vector, or PPTX from raster generation.
- When adding a template, update this file, `references/template-routing.md`, and relevant category docs if needed.
