local runner = require("maxa.interactions.chat.tools.builtin.runtime.rg_search")
local query = require("maxa.interactions.chat.tools.builtin.runtime.search_query")
local query_schema = {
  anyOf = {
    { type = "string", minLength = 1 },
    { type = "array", items = { type = "string", minLength = 1 }, minItems = 1 },
  },
}

return {
  name = "search",
  display = function(args)
    local detail = require("maxa.interactions.chat.tools.display_helpers").query_detail("search", args.text or args.regex, args)
    return { summary = detail ~= "search" and args.output == "files" and (detail .. " · files") or detail }
  end,
  description = "Search file contents using exact text or explicit Rust regex on the scope's WSL or Windows host; a file scope searches only that file. Supply text or regex, not both. Loaded Abilities may intercept calls with their documented query semantics, including queryless position operations. Oversized results are saved to a temporary file for read.",
  inputSchema = {
    type = "object",
    additionalProperties = false,
    ["not"] = { required = { "text", "regex" } },
    properties = {
      scope = { type = { "string", "null" }, description = "Default: project-relative or absolute file/directory; empty/null uses project root, @name resolves an installed Ability root. Loaded Ability scripts may interpret this value.", default = "." },
      text = vim.tbl_extend("force", query_schema, { description = "Original text or nonempty text list, matched literally with OR semantics; do not regex-escape code text." }),
      regex = vim.tbl_extend("force", query_schema, { description = "Rust regex or nonempty regex list with OR semantics; mutually exclusive with text." }),
      case = { type = { "string", "null" }, enum = { "sensitive", "insensitive", "smart", vim.NIL }, description = "Content case handling; null uses sensitive.", default = "sensitive" },
      include = { anyOf = { { type = "string" }, { type = "array", items = { type = "string" } }, { type = "null" } }, description = "Optional file path glob or list; any match includes a file. Null omits the filter." },
      exclude = { anyOf = { { type = "string" }, { type = "array", items = { type = "string" } }, { type = "null" } }, description = "Optional file path glob or list; exclusions win over includes. Null omits the filter." },
      hidden = { type = { "boolean", "null" }, description = "Include hidden files; null uses false.", default = false },
      no_ignore = { type = { "boolean", "null" }, description = "Ignore .gitignore/.ignore rules; null uses false, hidden files still require hidden=true.", default = false },
      max_results = { type = { "integer", "null" }, minimum = 1, description = "Optional positive matched-line/file limit; null means no count limit." },
      output = { type = { "string", "null" }, enum = { "matches", "files", vim.NIL }, description = "Return matched lines or unique matching file paths; null uses matches.", default = "matches" },
    },
  },
  prepare = query.prepare,
  run = function(context, response)
    return runner.run("search", context, response)
  end,
}
