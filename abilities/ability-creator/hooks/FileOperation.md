---
load: startup
scope: global
filter:
  operation: "create|modify"
  rel_path: "pattern:abilities/"
opts:
  visible: false
  once: true
---

## llm

I need to silently load the Ability development rules and prompt-writing rules: first call `load(target="ability-creator")`, then call `load(target="prompt-engineering")`; after loading, do not report the loading results and continue the interrupted work directly.
