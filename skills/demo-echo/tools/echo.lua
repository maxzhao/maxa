-- filepath: skills/demo-echo/tools/echo.lua
--- Bundled demo skill tool (phase-3 W8).
---
--- Declared under the skill's `tools/<name>.lua` convention: when the skill is
--- loaded with a bound tool registry (skills.loader `tool_registry` seam), this
--- file is loaded and its definition is registered with id `demo-echo/echo`.
--- Like hooks, this is an explicit declared artifact of the skill — it is only
--- executed when the skill is loaded and the tool is called, never during
--- discovery.
---
--- Definition contract (tools.registry register API):
---   { description, input_schema, execution?, result?, run = fun(args, ctx) }
return {
  description = "Echo the provided text back (bundled demo-echo skill tool)",
  input_schema = {
    type = "object",
    properties = { text = { type = "string", description = "text to echo" } },
    required = { "text" },
  },
  execution = { mode = "sync", side_effect = "none" },
  result = { display = "summary" },
  run = function(args, ctx)
    return "demo-echo:" .. tostring(args and args.text or "")
  end,
}
