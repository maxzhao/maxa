-- Runtime-authored flat invocation records for the single-call runs entrypoint.
-- These are execution provenance, not claims of native model-generated calls.
local M = {}
local params = require("maxa.mcphub.native_servers.shared.params")

function M.expand(call, runs, chat)
  local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
  local inventory = require("maxa.interactions.chat.tools.builtin")
  local run = inventory.resolve("run")
  local declaration = vim.json.decode(call["function"].arguments)
  if call.thought_signature or call.thoughtSignature then
    return nil, "runs expansion is unavailable for signed tool-call metadata; use native sibling calls."
  end
  local used = {}
  for _, message in ipairs(chat.messages or {}) do
    for _, existing in ipairs(message.tools and message.tools.calls or {}) do
      local existing_id = existing.call_id or existing.id
      if existing_id then used[existing_id] = true end
      if (existing.call_id or existing.id) == (call.call_id or call.id) then
        local reasoning = message.reasoning
        if type(reasoning) == "table" then
          for _, item in pairs(reasoning) do
            if type(item) == "table" and item.signature then return nil, "runs expansion cannot rewrite signed reasoning history." end
          end
          if reasoning.signature then return nil, "runs expansion cannot rewrite signed reasoning history." end
        end
      end
    end
  end
  local calls, raw_runs, execution_params = { call }, {}, {}
  for index, raw in ipairs(runs) do
    local ready, err = adapter.prepare(run, { params = raw, run_member = true, chat = chat,
      cwd = chat.opts.cwd, active_wrappers = {}, active_extensions = {} })
    if not ready then return nil, "runs[" .. index .. "]: " .. tostring(err) end
    local p = ready.params
    p.title = params.default(p.title, declaration.title)
    local name, args = "run", vim.deepcopy(raw)
    if p.scope == "tool" and inventory.resolve(p.command) and (p.opts or {}).async ~= true then
      name, args = p.command, vim.deepcopy(p.args or {})
    end
    -- Required titles are execution-only defaults, never canonical call arguments.
    local schema = inventory.resolve(name).inputSchema
    if schema.properties and schema.properties.title and vim.tbl_contains(schema.required or {}, "title")
      and params.is_absent(args.title) then
      execution_params[index + 1] = vim.tbl_extend("force", {}, args, { title = p.title })
    end
    local seed = vim.fn.sha256(tostring(call.call_id or call.id) .. ":multicall:" .. index):sub(1, 32)
    if used["call_multicall_" .. seed] then return nil, "Generated multicall member identity already exists in this Chat." end
    used["call_multicall_" .. seed] = true
    calls[#calls + 1] = { id = "fc_multicall_" .. seed, call_id = "call_multicall_" .. seed,
      type = "function", ["function"] = { name = name, arguments = vim.json.encode(args) },
      _multicall_member = { parent_call_id = call.call_id or call.id, index = index } }
    raw_runs[index] = vim.deepcopy(raw)
  end
  return calls, raw_runs, execution_params
end

function M.stage(chat, plan)
  local id = plan.entries[1].call.call_id or plan.entries[1].call.id
  for _, message in ipairs(chat.messages or {}) do
    for _, call in ipairs(message.tools and message.tools.calls or {}) do
      if (call.call_id or call.id) == id then
        local calls = {}
        for _, entry in ipairs(plan.entries) do calls[#calls + 1] = vim.deepcopy(entry.call) end
        message.tools.calls = calls
        message._meta = message._meta or {}
        message._meta.multicall_expansion = { parent_call_id = id, members = #calls - 1, source = "runs", state = "executing" }
        return true
      end
    end
  end
  return nil, "multicall declaration history record is unavailable"
end

function M.commit(chat, plan)
  local expansion = plan.native_batch and plan.native_batch.expansion
  if not expansion or expansion.committed then return end
  local parent = plan.entries[1].call
  local id = parent.call_id or parent.id
  for _, message in ipairs(chat.messages or {}) do
    for _, call in ipairs(message.tools and message.tools.calls or {}) do
      if (call.call_id or call.id) == id then
        local args = vim.json.decode(parent["function"].arguments)
        args.runs = nil
        local declaration = vim.deepcopy(parent)
        declaration["function"].arguments = vim.json.encode(args)
        local calls = { declaration }
        for index = 2, #plan.entries do calls[#calls + 1] = vim.deepcopy(plan.entries[index].call) end
        message.tools.calls = calls
        message._meta = message._meta or {}
        message._meta.multicall_expansion = { parent_call_id = id, members = #calls - 1, source = "runs", state = "closed" }
        expansion.committed = true
        return
      end
    end
  end
end
return M
