# UI/UX Mockups

Use for apps, websites, dashboards, component libraries, and product UI screenshots. Write prompts like product specs, not style blurbs.

Shared image generation/editing techniques are owned by `references/craft.md`; the schema and example below are optional domain briefs. Use `references/preflight.md` for runtime-dependent request settings and exact-size handling, separately from visual prompt text.

## Mini Schema

```text
Design a [platform/device] UI mockup for a fictional product named "[product]".
Screen/page: [page purpose].
Canvas: [portrait/landscape/square], [device or browser frame if needed].
Layout: [header/sidebar/cards/chart/table/nav].
Content: include exact in-image text "...".
Data: [provided numbers, labels, list items; explicitly labeled sample data only for fictional concepts].
Visual system: [palette], [typography], [spacing], [icon style].
Constraints: crisp typography, clean spacing, precise icon alignment, production-quality mockup, no placeholder gibberish.
```

## Required Controls

- Product name and page name.
- Platform/device: mobile phone, desktop dashboard, browser window, design system board.
- Information architecture: header, cards, chart, table, list, bottom nav, sidebar.
- Real copy and data: title, buttons, metrics, dates, list items.
- Visual system: primary/accent colors, type feel, spacing, radius, shadow.

## Recommended Sizes

- Mobile app concept: `1024x1536` or `2160x3840`.
- Desktop dashboard: `1536x1024` or `2048x1152`.
- Design system board: `1024x1024` or `2048x2048`.

## Pitfalls

- Do not write only `modern clean UI`.
- Do not let the model invent lots of text; provide key short copy.
- Require `crisp typography` and `no placeholder gibberish`.
- Charts need supplied labels, units, and data; do not invent production metrics. Mark fictional sample data explicitly.
- Preserve required modules and exact copy in complex dashboards. Improve layout and typography rather than dropping cards, rows, columns, or text automatically.

## Prompt Skeleton

```text
Design a polished mobile finance app UI mockup for a fictional product named "AURAE", shown on a tall smartphone screen.
Layout: top header, account summary card, spending chart, recent transactions list, and bottom navigation.
Include exact in-image text: "AURAE", "Good morning, Lina", "Total balance $12,480.36", "Income +$4,200", "Spent -$1,830", "Home", "Cards", "Budget", "Profile".
Use a calm palette of deep navy, mint green, warm gray, and white. Prioritize crisp typography, clean spacing, precise icon alignment, realistic app hierarchy, and production-quality mockup rendering. Avoid placeholder gibberish and inconsistent icons.
```
