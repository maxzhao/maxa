# App Store Screenshot

Use for App Store / Google Play upload screenshots, device screenshot compositions, competitor visual analysis, and extending existing app screenshots. Inspired by store-art workflows such as `hypersocialinc/shots`; this file keeps structure and pitfalls only, not copied prompts.

## Use Cases

- App Store / Google Play listing screenshots.
- iPhone / Android device-frame UI compositions.
- Benefit-first screenshot copy and product value pages.
- Store-art directions from existing app screenshots, website summaries, or competitor visual style.
- Screenshot series: cover, feature page, social proof, pricing, privacy/security.

Shared image generation/editing techniques are owned by `references/craft.md`; the schema and example below are optional domain briefs. Use `references/preflight.md` for runtime-dependent request settings and exact-size handling, separately from visual prompt text.

## Mini Schema

```text
Create an app store screenshot composition for a fictional app named "[app_name]".
Store target: [App Store / Google Play], [device family], [upload purpose].
Canvas: [portrait/landscape], [single screenshot / 3-screen set / device mockup board].
Real UI source: [provided screenshot / described screen], preserve actual features and navigation.
Benefit headline: "[short headline]".
Support copy: "[short supporting line]".
Layout: [device frame placement], [background], [badge/callout style].
Visual system: [palette], [typography], [icon style], [brand mood].
Constraints: faithful UI, no invented features, readable short copy, safe margins, no fake awards or store badges unless provided.
```

## Required Controls

- App name, platform, and store target.
- Device and upload purpose: iPhone/Android, portrait/landscape, first screenshot or sequence.
- Real UI source: preserve provided screenshots; if absent, state that output is a fictional UI concept.
- Headline per screenshot: exact supplied copy; when drafting new copy, prefer a readable, benefit-first headline.
- Feature boundary: show only provided or explicitly described functions.
- Visual system: brand color, background, device frame, whitespace, safe area.

## Recommended Sizes

- Portrait composition concept: `1024x1536`; taller portrait concept: `2160x3840`.
- Landscape banner or multi-device concept: `1536x1024` or `2048x1152`.
- Square concept board / screenshot thumbnails: `1024x1024` or `2048x2048`.

These are generation planning sizes, not store upload specifications. Preserve the user's exact upload dimensions and resolve unsupported requests through `references/preflight.md`; do not silently rescale.

## Pitfalls

- Real UI fidelity beats visual exaggeration; do not alter navigation, charts, button meaning, or brand text. If the screenshot itself must remain pixel-identical, composite it deterministically instead of relying on a generative edit.
- Do not invent features, awards, ratings, certification marks, or platform badges.
- Give the main headline visual priority. Preserve required copy; repair text placement, spacing, or typography rather than automatically shortening it.
- Specify device size, safe area, and upload purpose; avoid covering status bar or gesture area.
- Competitor analysis abstracts layout/rhythm/hierarchy only; do not copy logos, assets, or store copy.

## Visual Verification

- Check headline, support copy, app name, and UI text readability.
- Check provided UI fidelity: navigation, buttons, chart meaning, feature boundary.
- Check device frame, safe area, title placement, and upload purpose.
- Check for unprovided awards, ratings, store badges, certifications, or third-party logos.

## Prompt Skeleton

```text
Create a portrait App Store screenshot composition for a fictional budgeting app named "AURAE".
Store target: Apple App Store, iPhone portrait upload screenshot, first screenshot in the listing.
Show one realistic iPhone device frame centered on a soft navy-to-mint gradient background.
Inside the device, preserve a truthful finance dashboard UI: header "AURAE", balance card "$12,480", spending chart, recent transactions, bottom navigation.
Benefit headline above the device: "Know where your money goes".
Support copy below: "Simple weekly insights, no spreadsheets".
Use crisp typography, large readable headline, safe margins, clean device shadow, and production-quality store artwork. Do not invent awards, ratings, bank logos, or unprovided features. Keep all UI text readable and faithful to the described app.
```
