---
name: json-canvas
description: Create and edit Obsidian JSON Canvas `.canvas` files with text/file/link/group nodes, edges, colors, layout, and validation.
---

# JSON Canvas Reference

Canvas files follow JSON Canvas Spec 1.0 and contain top-level arrays:

```json
{"nodes": [], "edges": []}
```

## Workflows

### Create Canvas

1. Create `.canvas` with `nodes` and `edges` arrays.
2. Generate unique 16-character lowercase hex IDs.
3. Add nodes with `id`, `type`, `x`, `y`, `width`, `height`.
4. Add edges with `fromNode` and `toNode` referencing existing node IDs.
5. Validate JSON, unique IDs, and edge references.

### Add Node

1. Parse existing canvas.
2. Generate non-colliding node ID.
3. Choose position avoiding overlap; leave 50-100px between nodes.
4. Append node; optionally append edges.
5. Validate IDs and references.

### Connect Nodes

1. Identify source/target node IDs.
2. Generate edge ID.
3. Set `fromNode`, `toNode`; optionally `fromSide`, `toSide`, `label`, `fromEnd`, `toEnd`.
4. Append edge and validate references.

### Edit Canvas

1. Parse JSON.
2. Locate node/edge by `id`.
3. Modify only required fields.
4. Write JSON and revalidate.

## Node Schema

Generic fields:

| Field | Required | Type | Notes |
| --- | --- | --- | --- |
| `id` | yes | string | unique 16-char hex |
| `type` | yes | string | `text`, `file`, `link`, `group` |
| `x`, `y` | yes | integer | top-left coordinates; can be negative |
| `width`, `height` | yes | integer | size in pixels |
| `color` | no | canvasColor | preset `"1"`-`"6"` or hex |

Text node:

```json
{"id":"6f0ad84f44ce9c17","type":"text","x":0,"y":0,"width":400,"height":200,"text":"# Hello\n\nMarkdown"}
```

Use `\n` for line breaks in JSON strings. Do not use literal `\\n` unless the output should show backslash+n.

File node:

```json
{"id":"a1b2c3d4e5f67890","type":"file","x":500,"y":0,"width":400,"height":300,"file":"Attachments/diagram.png"}
```

Optional `subpath` starts with `#` for heading/block links.

Link node:

```json
{"id":"c3d4e5f678901234","type":"link","x":1000,"y":0,"width":400,"height":200,"url":"https://obsidian.md"}
```

Group node:

```json
{"id":"d4e5f6789012345a","type":"group","x":-50,"y":-50,"width":1000,"height":600,"label":"Project Overview","color":"4"}
```

Optional group fields: `label`, `background`, `backgroundStyle` (`cover`, `ratio`, `repeat`). Position child nodes inside group bounds.

## Edge Schema

| Field | Required | Values |
| --- | --- | --- |
| `id` | yes | unique string |
| `fromNode`, `toNode` | yes | existing node IDs |
| `fromSide`, `toSide` | no | `top`, `right`, `bottom`, `left` |
| `fromEnd` | no | `none` or `arrow`; default `none` |
| `toEnd` | no | `none` or `arrow`; default `arrow` |
| `color` | no | canvasColor |
| `label` | no | string |

```json
{"id":"0123456789abcdef","fromNode":"6f0ad84f44ce9c17","fromSide":"right","toNode":"a1b2c3d4e5f67890","toSide":"left","toEnd":"arrow","label":"leads to"}
```

## Colors And Layout

Colors: preset `"1"`-`"6"` or hex such as `"#FF0000"`; preset visuals are app-defined.

Layout rules:

- `x` increases right; `y` increases down.
- Space nodes 50-100px apart; leave 20-50px padding inside groups.
- Align to multiples of 10 or 20.
- Suggested sizes: small text 200-300×80-150; medium 300-450×150-300; large 400-600×300-500; file preview 300-500×200-400; link preview 250-400×100-200.

## Validation Checklist

After create/edit, verify:

- JSON parses.
- All node and edge `id` values are unique.
- Every `fromNode` and `toNode` exists.
- Required node-specific fields exist: `text`, `file`, or `url`.
- Node `type` is `text|file|link|group`.
- Side/end/color values are valid.
- Text strings use valid JSON escaping for newlines.

References: JSON Canvas Spec 1.0 https://jsoncanvas.org/spec/1.0/ and https://github.com/obsidianmd/jsoncanvas
