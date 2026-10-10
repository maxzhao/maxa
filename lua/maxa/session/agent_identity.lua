-- Agent identity owns saved ancestry separately from the current invocation.
local M = {}

local function save_id(holder)
  return holder and ((holder.opts and holder.opts.save_id) or holder.save_id)
end
M.save_id = save_id

function M.history(holder)
  if not holder then return { kind = "main" } end
  local agent = holder._meta and holder._meta.agent or holder.agent
  if agent and (agent.kind == "main" or agent.kind == "subagent") then return agent end
  local trace = holder._meta and holder._meta.session_trace or holder.session_trace
  if trace and (trace.session_role == "subagent" or trace.session_role == "resumed") then
    return { kind = "subagent", root_save_id = trace.root_save_id or trace.root_trace_id,
      span_id = trace.span_id, parent_span_id = trace.parent_span_id }
  end
  return { kind = "main", root_save_id = save_id(holder) }
end

function M.is_subagent(holder)
  return holder ~= nil and (holder._agent_execution ~= nil
    or (tonumber(holder._subagent_recursion_depth) or 0) > 0 or M.history(holder).kind == "subagent")
end

function M.is_main(holder)
  return holder ~= nil and not holder._maxa_hidden_image_analysis and not holder._is_rescue_session
    and not (holder.opts and holder.opts.preserve_main)
    and not require("maxa.session.history_core").is_unsavable_save_id(save_id(holder), "analyze")
    and not M.is_subagent(holder)
end

function M.bind(parent, child)
  if not child then return end
  child._agent_execution = { parent = parent, root = parent and M.root(parent) or nil }
  child._subagent_recursion_depth = ((parent and tonumber(parent._subagent_recursion_depth)) or 0) + 1
end

function M.parent(chat)
  return chat and chat._agent_execution and chat._agent_execution.parent
end

function M.root(chat)
  return chat and chat._agent_execution and chat._agent_execution.root or chat
end

function M.release(chat)
  if chat then chat._tool_display_owner = nil end
  if chat and chat._agent_execution then
    chat._agent_execution = nil
    chat._subagent_recursion_depth = nil
  end
end

function M.make_child(parent)
  local agent = M.history(parent)
  return { kind = "subagent", parent_save_id = save_id(parent),
    root_save_id = agent.root_save_id or save_id(parent), depth = (tonumber(agent.depth) or 0) + 1 }
end

function M.initialize(chat, args)
  chat._meta = vim.deepcopy(args._meta or {})
  chat._meta.last_dialogue_at = chat._meta.last_dialogue_at or args.history_updated_at
  chat.opts.save_id = chat.opts.save_id or require("maxa.session.history_core").generate_save_id()
  if args.agent_child and not args.agent_preserve_history then
    chat._meta.agent = M.make_child(args.agent_parent)
  elseif not chat._meta.agent then
    chat._meta.agent = vim.deepcopy(M.history(chat))
  end
  if chat._meta.agent.kind == "main" then chat._meta.agent.root_save_id = chat.opts.save_id end
  if args.agent_child then M.bind(args.agent_parent, chat) end
  args.agent_parent = nil
end

function M.reidentify(holder, independent)
  holder._meta = holder._meta or {}
  local agent = independent and { kind = "main" } or vim.deepcopy(M.history(holder))
  if agent.kind == "main" then agent.root_save_id, agent.parent_save_id, agent.depth = save_id(holder), nil, nil end
  holder._meta.agent = agent
end

function M.index_fields(holder)
  return { agent = vim.deepcopy(M.history(holder)), last_dialogue_at = holder._meta and holder._meta.last_dialogue_at }
end

function M.touch_dialogue(chat)
  if chat._agent_execution and M.history(chat).kind == "main" then return end
  chat._meta = chat._meta or {}
  chat._meta.last_dialogue_at = os.time()
end

function M.main_chats(chats)
  local result = {}
  for _, entry in ipairs(chats or {}) do
    local chat = entry.chat or entry
    if M.is_main(chat) then result[#result + 1] = chat end
  end
  return result
end

-- Missing and cyclic ancestry produces detached roots, never lost records.
function M.tree(items)
  local tree = { roots = {}, by_id = {} }
  local spans = {}
  for _, item in ipairs(items or {}) do
    local node = { item = item, id = item.save_id, children = {} }
    tree.by_id[node.id] = node
    local trace = item.session_trace
    if trace and trace.span_id then spans[trace.span_id] = node.id end
  end
  local parents = {}
  for _, node in pairs(tree.by_id) do
    local agent = M.history(node.item)
    if agent.kind == "subagent" then
      parents[node.id] = agent.parent_save_id or spans[agent.parent_span_id]
        or (agent.root_save_id ~= node.id and agent.root_save_id or nil)
    end
  end
  for _, node in pairs(tree.by_id) do
    local parent_id = parents[node.id]
    local seen, cursor = { [node.id] = true }, parent_id
    while cursor and tree.by_id[cursor] and not seen[cursor] do
      seen[cursor] = true
      cursor = parents[cursor]
    end
    if cursor and seen[cursor] then parent_id = nil end
    node.parent = tree.by_id[parent_id]
    if node.parent then node.parent.children[#node.parent.children + 1] = node
    else tree.roots[#tree.roots + 1] = node end
  end
  local function recent(a, b)
    local at, bt = a.item.last_dialogue_at or a.item.updated_at or 0, b.item.last_dialogue_at or b.item.updated_at or 0
    return at == bt and a.id < b.id or at > bt
  end
  table.sort(tree.roots, recent)
  for _, node in pairs(tree.by_id) do table.sort(node.children, recent) end
  return tree
end

function M.ancestors(node)
  local result, seen = {}, {}
  while node and node.parent and not seen[node.parent.id] do
    node = node.parent
    seen[node.id] = true
    result[#result + 1] = node
  end
  return result
end

function M.children(chat, chats)
  local result = {}
  for _, entry in ipairs(chats or {}) do
    local child = entry.chat or entry
    if M.parent(child) == chat then result[#result + 1] = child end
  end
  return result
end

function M.window_opts(chat, requested)
  if M.is_subagent(chat) then
    return vim.tbl_extend("force", {}, requested or {}, { layout = "float", relative = "editor", width = 0.8, height = 0.8,
      title = "SubAgent: " .. tostring(chat.title or chat.opts and chat.opts.title or "") })
  end
  return requested
end

return M
