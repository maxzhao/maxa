---
name: obsidian-bases
description: Create and edit Obsidian Bases `.base` files with YAML views, filters, formulas, properties, summaries, table/cards/list/map views, and formula troubleshooting.
---

# Obsidian Bases Reference

Bases are `.base` files containing YAML. Use this reference for database-like views of notes.

## Workflow

1. Create valid YAML `.base` file.
2. Define global `filters` by tag, folder, property, date, etc.
3. Optionally define `formulas` and `summaries`.
4. Configure `properties` display names/settings.
5. Add one or more `views` with `type`, `name`, `order`, optional filters/group/limit/summaries.
6. Validate YAML, referenced properties/formulas, quoting, and Duration math.
7. Open in Obsidian when possible to confirm rendering.

## Schema Skeleton

```yaml
filters:
  and: []
  or: []
  not: []

formulas:
  formula_name: 'expression'

properties:
  property_name:
    displayName: "Display Name"
  formula.formula_name:
    displayName: "Formula Display Name"
  file.ext:
    displayName: "Extension"

summaries:
  custom_summary_name: 'values.mean().round(3)'

views:
  - type: table | cards | list | map
    name: "View Name"
    limit: 10
    groupBy:
      property: property_name
      direction: ASC | DESC
    filters:
      and: []
    order:
      - file.name
      - property_name
      - formula.formula_name
    summaries:
      property_name: Average
```

## Filters

```yaml
# Single filter
filters: 'status == "done"'

# AND
filters:
  and:
    - 'status == "done"'
    - 'priority > 3'

# OR / NOT / nested
filters:
  or:
    - file.hasTag("article")
    - and:
        - file.hasTag("book")
        - file.hasLink("Textbook")
    - not:
        - file.inFolder("Required Reading")
```

Operators: `==`, `!=`, `>`, `<`, `>=`, `<=`, `&&`, `||`, `!`.

## Properties And Formulas

Property types:

- Note properties from frontmatter: `author` or `note.author`.
- File properties: `file.name`, `file.basename`, `file.path`, `file.folder`, `file.ext`, `file.size`, `file.ctime`, `file.mtime`, `file.tags`, `file.links`, `file.backlinks`, `file.embeds`, `file.properties`.
- Formula properties: `formula.my_formula`.

`this` refers to the base file in main content, the embedding file when embedded, and the active file in sidebar.

Formula examples:

```yaml
formulas:
  total: "price * quantity"
  status_icon: 'if(done, "✅", "⏳")'
  formatted_price: 'if(price, price.toFixed(2) + " dollars")'
  created: 'file.ctime.format("YYYY-MM-DD")'
  days_old: '(now() - file.ctime).days'
  days_until_due: 'if(due_date, (date(due_date) - today()).days, "")'
```

Common functions: `date(string)`, `now()`, `today()`, `if(condition, trueResult, falseResult?)`, `duration(string)`, `file(path)`, `link(path, display?)`.

## Duration Rules

Subtracting dates returns Duration, not Number. Access a field before numeric functions.

```yaml
# Correct
"(date(due_date) - today()).days"
"(now() - file.ctime).days"
"(date(due_date) - today()).days.round(0)"

# Wrong
# "((date(due) - today()) / 86400000).round(0)"
# "(now() - file.ctime).round(0)"
```

Duration units: `y/year/years`, `M/month/months`, `d/day/days`, `w/week/weeks`, `h/hour/hours`, `m/minute/minutes`, `s/second/seconds`.

## View Types

```yaml
# Table
views:
  - type: table
    name: "Active Tasks"
    order: [file.name, status, due]
    summaries:
      price: Sum

# Cards
views:
  - type: cards
    name: "Library"
    order: [cover, file.name, author]

# List
views:
  - type: list
    name: "Simple List"
    order: [file.name, status]

# Map: requires latitude/longitude properties and Maps community plugin
views:
  - type: map
    name: "Locations"
```

Default summaries: `Average`, `Min`, `Max`, `Sum`, `Range`, `Median`, `Stddev`, `Earliest`, `Latest`, `Checked`, `Unchecked`, `Empty`, `Filled`, `Unique`.

## Minimal Examples

Task tracker:

```yaml
filters:
  and:
    - file.hasTag("task")
    - 'file.ext == "md"'

formulas:
  days_until_due: 'if(due, (date(due) - today()).days, "")'
  is_overdue: 'if(due, date(due) < today() && status != "done", false)'
  priority_label: 'if(priority == 1, "🔴 High", if(priority == 2, "🟡 Medium", "🟢 Low"))'

views:
  - type: table
    name: "Active Tasks"
    filters:
      and:
        - 'status != "done"'
    order:
      - file.name
      - status
      - formula.priority_label
      - due
      - formula.days_until_due
```

Daily notes index:

```yaml
filters:
  and:
    - file.inFolder("Daily Notes")
    - '/^\d{4}-\d{2}-\d{2}$/.matches(file.basename)'

formulas:
  word_estimate: '(file.size / 5).round(0)'
  day_of_week: 'date(file.basename).format("dddd")'

views:
  - type: table
    name: "Recent Notes"
    limit: 30
    order: [file.name, formula.day_of_week, formula.word_estimate, file.mtime]
```

## Embedding

```markdown
![[MyBase.base]]
![[MyBase.base#View Name]]
```

## YAML Quoting And Troubleshooting

Rules:

- Quote strings containing `:`, `{}`, `[]`, `,`, `&`, `*`, `#`, `?`, `|`, `-`, `<`, `>`, `=`, `!`, `%`, `@`, or backtick.
- Use single quotes around formulas that contain double quotes: `'if(done, "Yes", "No")'`.
- Guard nullable properties with `if()`.
- Ensure every `formula.X` in `order` or `properties` is defined under `formulas`.

Examples:

```yaml
# Wrong
displayName: Status: Active
formulas:
  label: "if(done, "Yes", "No")"

# Correct
displayName: "Status: Active"
formulas:
  label: 'if(done, "Yes", "No")'
```

```yaml
# Wrong
"(date(due_date) - today()).days"

# Correct
'if(due_date, (date(due_date) - today()).days, "")'
```

References: https://help.obsidian.md/bases/syntax, `/bases/functions`, `/bases/views`, `/formulas`.
