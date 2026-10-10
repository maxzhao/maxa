-- A declaration is executed only by the completed model-batch owner.
local params = require("maxa.mcphub.native_servers.shared.params")
local member_properties = vim.deepcopy(require("maxa.interactions.chat.tools.builtin.tools.builtin_run").inputSchema.properties)
member_properties.title = { type = { "string", "null" }, description = "Optional nonblank member display title. Omitted/null stays untitled; inherited execution defaults are not written to member history or model arguments." }
return {
  name = "multicall",
  display = function(args)
    return { summary = require("maxa.interactions.chat.tools.display_helpers").title_detail("multicall", args) }
  end,
  description = [[Batch 1–16 requests in parallel or sequence. Use runs for a single-call batch, or place this first/unique declaration before native builtin sibling calls in the same model response; never mix both forms. All members must pass preflight before execution. Interactive members and nested batches are prohibited. Returns batch completion facts; member results remain separate.]],
  inputSchema = {
    type = "object", additionalProperties = false,
    properties = {
      title = { type = "string", minLength = 1, description = "Required nonblank batch display title." },
      runs = { type = "array", minItems = 1, maxItems = 16, description = "Run requests in result order; required for a single-call batch and mutually exclusive with native sibling calls. Member titles are normally omitted.",
        items = { type = "object", additionalProperties = false, properties = member_properties, required = { "command" } } },
      mode = { type = "string", enum = { "parallel", "sequence" }, default = "parallel", description = "Scheduling mode; default parallel." },
      max_concurrency = { type = "integer", minimum = 0, maximum = 16, default = 0, description = "Parallel active-invocation limit; 0 (default) starts all members without a concurrency cap; 1–16 sets a cap. Ignored in sequence." },
      on_error = { type = "string", enum = { "stop", "continue" }, description = "Sequence only: stop (default) or continue after an invocation error. Prohibited in parallel." },
    }, required = { "title" },
  },
  prepare = function(context)
    if not context.native_batch_declaration then
      return nil, "multicall must be the first declaration in a complete native model tool batch."
    end
    if context.chat and context.chat._maxa_hidden_image_analysis then
      return nil, "Hidden image-analysis child cannot use multicall."
    end
    local p = vim.deepcopy(context.params)
    if type(p.title) ~= "string" or not p.title:find("%S") then return nil, "title must be a nonblank string." end
    p.mode = params.default(p.mode, "parallel")
    p.max_concurrency = params.default(p.max_concurrency, 0)
    if p.mode == "parallel" and p.on_error ~= nil then return nil, "on_error is permitted only in sequence mode." end
    if p.mode == "sequence" then p.on_error = params.default(p.on_error, "stop") end
    return p
  end,
  run = function(_, response)
    return response:error("multicall requires a complete native model tool batch; nested/standalone execution is prohibited.")
  end,
}
