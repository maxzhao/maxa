# GenAI Category Index

Choose the closest category file for the user goal; read one relevant category, or at most two for a mixed deliverable. `craft.md` owns the shared prompting contract and must be read before writing image prompts. Categories are Maxa task heuristics, not extra model requirements; use only applicable controls and preserve user text/data. `preflight.md` owns settings; case reverse engineering lives in `reverse-engineering.md`.

## Production Deliverables First

App Store / Google Play screenshots, PPT/slides, scientific figures, storyboards, brand logos, and business visuals are production visual deliverables. Route them to their dedicated categories instead of generic UI/UX, infographic, or poster categories. Use generic categories only when the user explicitly asks for the interface itself, a general explainer, or an event poster.

| Category | File | Use cases |
|---|---|---|
| App Store Screenshot | `categories/app-store-screenshot.md` | App Store / Google Play upload screenshots, device screenshot compositions, benefit-first store art, competitor visual analysis |
| Scientific Figure | `categories/scientific-figure.md` | Research figure, method figure, pipeline diagram, cohort flow, benchmark chart, conference poster |
| Presentation Slide | `categories/presentation-slide.md` | 16:9 slide, pitch deck cover, data slide, executive update, LinkedIn carousel cover |
| Storyboard Video Seed | `categories/storyboard-video-seed.md` | 4/6/9-panel storyboard, short-video visual seed, comic drama, news visualization, I2V reference |
| Game Sprite | `categories/game-sprite.md` | Game character sprite, sprite sheet, animation frame, pixel-art/RPG/fighter/platformer sprite |
| Brand Logo | `categories/brand-logo.md` | Logo concept grid, brand identity board, app icon, wordmark/mark/lockup, touchpoint board |
| Business Visual | `categories/business-visual.md` | SWOT card, strategy one-pager, executive dashboard, business infographic, consulting slide visual |
| UI/UX | `categories/ui-ux.md` | App, Web, dashboard, design system, product UI screenshot |
| Infographic / Technical Diagram | `categories/infographic.md` | Educational infographic, technical explanation, knowledge graph, flow/architecture diagram |
| Poster / Typography | `categories/poster-typography.md` | Poster, cover, event visual, Chinese title, strong typography |
| Product / Ecommerce | `categories/product.md` | Product hero, packaging, product detail concept, brand hero |
| Photography / Realism | `categories/photography.md` | Realistic photo, cinematic scene, screen photography, lifestyle image |
| Character / Figure | `categories/character.md` | Character design, character sheet, stylized figure, series consistency |
| Reference Edit | `categories/edit-reference.md` | `image_edit`, style transfer, multi-reference fusion, localized intent rewrite |

## Routing Rules

- “App Store screenshot”, “Google Play”, “store upload”, “app screenshot promotion”, “competitor screenshot analysis” → App Store Screenshot.
- “paper figure”, “scientific figure”, “method figure”, “pipeline”, “cohort flow”, “benchmark chart”, “poster session” → Scientific Figure.
- “PPT”, “slide”, “pitch deck”, “executive update”, “carousel cover”, “presentation page” → Presentation Slide.
- “storyboard”, “panel”, “I2V visual seed”, “comic board” → Storyboard Video Seed.
- “sprite”, “sprite sheet”, “pixel art character”, “animation frame”, “game character frame”, “RPG sprite”, “fighter sprite”, “platformer sprite” → Game Sprite.
- “logo”, “brand identity”, “app icon”, “wordmark”, “lockup”, “brand board” → Brand Logo.
- “SWOT”, “strategy one-pager”, “executive dashboard”, “consulting slide”, “business infographic” → Business Visual.
- “interface”, “App”, “Web page”, “dashboard”, “component library” and not store-upload art → UI/UX.
- “explain”, “flow”, “architecture”, “graph”, “RAG”, “tutorial”, “educational” and not a research publication figure → Infographic / Technical Diagram.
- “poster”, “cover”, “title”, “event”, “brand campaign”, “large Chinese text” and not slide/logo → Poster / Typography.
- “product”, “packaging”, “ecommerce”, “detail page”, “ad main image” → Product / Ecommerce.
- “real photo”, “camera”, “cinematic”, “street photo”, “interior”, “landscape” → Photography / Realism.
- “character”, “character design”, “expression”, “pose”, “card art”, “standing illustration” → Character / Figure.
- User provides `image_paths` or says “edit this image” → Reference Edit; if it is also a production deliverable, read that category too. Every resulting input/output comparison also follows `references/image-edit-review-standard.md`: perceptual first-glance fidelity by default, with strict correspondence scoped only to named user/downstream invariants.

## Common Mixed Categories

- Reference Edit + any target category: read `edit-reference.md`, then target category.
- App Store Screenshot + UI/UX: preserve real app screenshot while packaging it for store upload.
- Scientific Figure + Infographic: publication figures need stricter labels, units, and post-edit strategy.
- Presentation Slide + Business Visual: slide plan first, then business deliverable structure.
- Storyboard Video Seed + Character: character consistency and multipanel visual DNA.
- Game Sprite + Character: character identity and costume invariants adapted to sprite scale and frame consistency.
- Brand Logo + Product/Ecommerce: extend brand board to package, app icon, or touchpoint.
- Product + Poster: commercial ad or launch visual.
- Photography + Product: realistic product photography.
- Character + Poster: character poster or card promo.
