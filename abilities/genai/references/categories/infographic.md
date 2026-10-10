# Infographic and Technical Diagrams

Use for infographics, explainers, flowcharts, architecture diagrams, RAG/AI explanations, educational charts, and research diagrams. Goal: clear information, not just attractive visuals.

Shared image generation/editing techniques are owned by `references/craft.md`; the schema and example below are optional domain briefs. Use `references/preflight.md` for runtime-dependent request settings and exact-size handling, separately from visual prompt text.

## Mini Schema

```text
Create a [diagram type] about [topic] for [audience].
Canvas: [landscape/portrait/square].
Layout: title area + [number] modules + central diagram + legend/notes.
Flow: [left-to-right/top-down/radial/layered].
Modules:
1. "[short title]" — [one sentence]
2. "[short title]" — [one sentence]
Exact labels: "...".
Style: [scientific poster/editorial card/classroom wall chart], restrained palette, readable labels, clean arrows.
Constraints: no random formulas, no unlabeled arrows, no garbled text.
```

## Diagram Types

- Process: flowchart / pipeline.
- System architecture: system architecture diagram / layered architecture.
- Concept relation: knowledge graph / network graph.
- Comparison: comparison table / split panel.
- Time: timeline.
- Multi-view data: small-multiples grid.
- Education: field guide / classroom wall chart / anatomy chart.

## Required Controls

- Topic and audience.
- Required module list and count; preserve every supplied module and relationship.
- Arrow direction and connection logic.
- Title, module titles, legend, units, axis labels.
- Style boundary: scientific / editorial / classroom; avoid vague “infographic”.

## Recommended Sizes

- Technical architecture / horizontal flow: `1536x1024` or `2048x1152`.
- Education poster / portrait explainer: `1024x1536` or `2160x3840`.
- Square knowledge graph: `1024x1024` or `2048x2048`.

## Pitfalls

- Dense diagrams need explicit grouping, reading order, and sufficient label space; do not delete required modules to reduce density.
- Preserve supplied labels and copy verbatim. Repair placement, typography, or layout rather than automatically shortening text; consult `references/preflight.md` for supported quality and resolution options.
- Arrows need source and target.
- Do not let the model invent formulas or pseudocode.
- Use white background, margins, and restrained colors unless a strong style is requested.

## Prompt Skeleton

```text
Create a landscape system architecture diagram explaining "RAG Retrieval Pipeline" for engineers.
Layout: title area at top, five left-to-right numbered modules, bottom legend strip.
Modules: 1 "User Query" — incoming question, 2 "Embedding" — vector representation, 3 "Retriever" — top-k document search, 4 "Context Builder" — selected chunks, 5 "LLM Answer" — grounded response.
Use arrows from left to right, with a small feedback loop labeled "Re-rank" between Retriever and Context Builder.
Exact labels: "Query", "Vector DB", "Top-k", "Context", "Grounded Answer".
Style: clean technical whitepaper diagram, restrained blue/gray palette, crisp readable labels, generous margins. Avoid random formulas, unlabeled arrows, and garbled microtext.
```
