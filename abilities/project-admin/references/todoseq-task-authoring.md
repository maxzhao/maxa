---
name: todoseq-task-authoring
description: Author, maintain, edit, and validate TODOseq Markdown task entries in Obsidian Vaults.
---

# TODOseq Task Authoring Guide

Use this when the user asks to create, edit, organize, or debug TODOseq task entries in Obsidian Markdown. This is not TODOseq plugin source development guidance.

Typical tasks: create TODOseq tasks, batch-edit state/priority/dates/tags, edit `SCHEDULED:` / `DEADLINE:` / `CLOSED:`, maintain checkbox subtasks, or debug Card Board visibility.

## Core Rules

1. TODOseq tasks must contain a status keyword; plain checkboxes alone are not TODOseq tasks.
2. State, date, priority, and tags must use TODOseq-parseable syntax.
3. Preserve existing formatting when editing: indentation, list marker, quote/callout prefixes, embed/footnote markers, block IDs, and tail text.
4. `SCHEDULED` and `DEADLINE` are distinct; do not merge into `due`.
5. `CLOSED` is completion semantics, not a planning date.
6. Vault business file paths are relative to Vault root.

## Task Forms

Plain keyword tasks:

```markdown
TODO Write project note #work
DOING Draft implementation plan [#A] #project
WAIT Waiting for review #blocked
DONE Publish result #done
```

Checkbox + keyword tasks:

```markdown
- [ ] TODO Write project note #work
- [x] DONE Publish result #done
```

Invalid as TODOseq: `- [ ] Write project note` because it has no TODOseq keyword. Checkbox status should match keyword: incomplete keywords use `[ ]`, completed keywords use `[x]`.

## Keywords

| Group | Keywords | Meaning |
| --- | --- | --- |
| inactive | `TODO`, `LATER` | not started |
| active | `NOW`, `DOING`, `IN-PROGRESS` | active/current |
| waiting | `WAIT`, `WAITING` | blocked/waiting |
| completed | `DONE`, `CANCELED`, `CANCELLED` | done/cancelled |
| archived | `ARCHIVED` | archived |

Rules:

- Vaults may configure custom keywords; inspect TODOseq config or existing tasks when the task depends on current settings.
- Do not invent unknown keywords unless user requests or config confirms them.
- `ARCHIVED` may be filtered by scanner; for display debugging, start with `TODO` / `DOING` / `WAIT` / `DONE`.

## Priority

```markdown
TODO Fix sync bug [#A] #bug
TODO Write docs [#B] #docs
TODO Clean up notes [#C]
```

Mapping: `[#A]` high, `[#B]` medium, `[#C]` low, no token = no priority.

Rules: priority token is not a tag; do not parse `[#A]` as `#A`. Replace/delete existing priority token rather than adding duplicates.

## Dates

```markdown
TODO Prepare release [#A] #release
  SCHEDULED: <2026-05-06 Wed>
  DEADLINE: <2026-05-08 Fri>

DONE Publish release #release
  CLOSED: [2026-05-09 Sat]
```

Semantics:

- `SCHEDULED:` planned/start date.
- `DEADLINE:` due date.
- `CLOSED:` completion date.

Rules:

- `SCHEDULED:` / `DEADLINE:` use active dates `<...>`.
- `CLOSED:` usually uses inactive date `[...]`.
- Date lines normally sit below the task and keep same/deeper indentation.
- Preserve repeaters such as `<2026-05-06 Wed +1d>`.
- Removing one date line must not remove the other date line or `CLOSED:`.

## Tags And Subtasks

Tags:

```markdown
TODO Draft proposal #project/client #writing
```

Avoid duplicate tags and never remove priority tokens when deleting tags.

Subtasks:

```markdown
TODO Parent task #project
  - [x] finished subtask
  - [ ] open subtask
```

Keep subtasks indented under the parent unless user asks to split tasks.

## Preservation In Quotes, Callouts, Footnotes, Embeds

Preserve TODOseq write-back fields and Markdown wrappers: `indent`, `listMarker`, `footnoteMarker`, `tail`, `quoteNestingLevel`, `embedReference`, `footnoteReference`, block IDs, callout/quote `>` prefixes. Do not reflow whole paragraphs for simple edits.

Example:

```markdown
> [!todo]
> TODO Review quoted task [#B] #review ^todo-review
```

## Templates

```markdown
TODO Task title #tag

TODO Task title [#A] #tag
  SCHEDULED: <2026-05-06 Wed>
  DEADLINE: <2026-05-08 Fri>

DOING Implement feature [#A] #feature
  SCHEDULED: <2026-05-06 Wed>
  - [x] write parser
  - [ ] add tests

DONE Ship feature #feature
  CLOSED: [2026-05-09 Sat]
```

## Edit Workflow

1. Read the relevant file segment; identify task line, date lines, and subtask range.
2. Determine target property: state, priority, scheduled, deadline, tags, text.
3. Make minimal local edit preserving formatting and wrappers.
4. If changing completion state, synchronize checkbox and `CLOSED:` semantics.
5. If editing scheduled/deadline, modify only the target date line.
6. Re-read the segment to confirm.
7. If Card Board visibility matters, confirm the task has TODOseq keyword in the current Vault file.

## Card Board Debug Checklist

If a task does not appear:

1. TODOseq plugin enabled.
2. Markdown file is inside current Obsidian Vault.
3. Task line has TODOseq keyword.
4. Default `TODOseq Groups` / `TODOseq Keywords` preset shows expected data.
5. If default preset works but “add column” does not, check `todoseq-card-board/data.json`: new columns belong in `todoSeqColumns`, not legacy CardBoard `columns`.

Project context note when relevant:

```text
.maxa/modules/TODOseq Card Board Current Usage Context.md
```

## Validation Checklist

- [ ] Every task has legal TODOseq keyword.
- [ ] Priority uses `[#A]` / `[#B]` / `[#C]`, with no duplicates.
- [ ] `SCHEDULED:` and `DEADLINE:` are separate and valid.
- [ ] `CLOSED:` is only completion semantics.
- [ ] Tags are not duplicated, and priority was not treated as tag.
- [ ] Subtask indentation is correct.
- [ ] Quotes, callouts, embeds, footnotes, block IDs, and tail text are preserved.
