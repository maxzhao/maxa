local runner = require("maxa.interactions.chat.tools.builtin.runtime.rg_search")

return {
  name = "glob",
  display = function(args)
    return { summary = require("maxa.interactions.chat.tools.display_helpers").query_detail("glob", args.patterns, args) }
  end,
  description = "List file paths under a directory using ripgrep on the scope's WSL or Windows host. Omitted, null or empty patterns list all discoverable files; large output is saved for read.",
  inputSchema = {
    type = "object",
    properties = {
      scope = { type = { "string", "null" }, description = "Project-root-relative or absolute directory; empty or null uses project root, @name resolves an installed Ability root.", default = "." },
      patterns = { anyOf = { { type = "string" }, { type = "array", items = { type = "string" } }, { type = "null" } }, description = "Optional file path glob or list; any match includes a file; null or empty lists all discoverable files." },
      exclude = { anyOf = { { type = "string" }, { type = "array", items = { type = "string" } }, { type = "null" } }, description = "Optional file path glob or list to exclude after pattern matches; null omits the filter." },
      hidden = { type = { "boolean", "null" }, description = "Include hidden files; null uses false.", default = false },
      no_ignore = { type = { "boolean", "null" }, description = "Ignore .gitignore/.ignore rules; null uses false, hidden files still require hidden=true.", default = false },
      max_results = { type = { "integer", "null" }, minimum = 1, description = "Optional positive file-count limit; null means no count limit." },
    },
    required = {},
  },
  run = function(context, response)
    return runner.run("glob", context, response)
  end,
}
