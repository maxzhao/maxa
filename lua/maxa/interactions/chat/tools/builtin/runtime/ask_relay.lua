-- Execution-local ancestry and reversible root entrances to child-owned asks.
local input = require("maxa.interactions.chat.tools.input")
local views = require("maxa.interactions.chat.tools.builtin.runtime.ask_display")
local M = {}
local bindings = setmetatable({}, { __mode = "k" })
local roots = setmetatable({}, { __mode = "k" })
local waits = setmetatable({}, { __mode = "k" })
local detach

local function root_state(chat)
  if not roots[chat] then
    local owner = { queue = {} }
    roots[chat] = owner
    if chat.add_callback then
      chat:add_callback("on_closed", function()
        detach(owner.active)
        for _, request in ipairs(owner.queue) do request.source.relay = nil end
        roots[chat], waits[chat] = nil, nil
      end)
    end
  end
  return roots[chat]
end

local function eligible(request)
  if request.source.terminal or request.source.submitting or not input.valid(request.root) then return false end
  local binding = request.binding
  while binding do
    if binding.closed then return false end
    if binding.async_id then
      local owner = waits[binding.parent]
      if not owner or not owner[binding.async_id] or owner[binding.async_id] == 0 then return false end
    end
    binding = binding.ancestor
  end
  return true
end

detach = function(request)
  if not request or not request.lease then return end
  local lease = request.lease
  request.lease = nil
  local owner = roots[request.root]
  if owner and owner.active == request then owner.active = nil end
  lease:close()
end

local function pump(root)
  local owner = roots[root]
  if not owner then return end
  if owner.active and not eligible(owner.active) then detach(owner.active) end
  if owner.active or root._tool_input or not input.valid(root) then return end
  for _, request in ipairs(owner.queue) do
    if eligible(request) then
      local content = views.request(request.source.display_params or request.source.params).blocks[1].content
      if request.source.preceding_text then
        content = request.source.preceding_text .. "\n\n---\n\n" .. content
      end
      local title = request.source.chat.opts and request.source.chat.opts.title or "SubAgent"
      local lease = input.open(root, {
        mode = request.source.params.mode, choices = request.source.params.choices,
        transient = true, prompt = "来自子代理：" .. tostring(title):gsub("[\r\n]", " ") .. "\n\n" .. content,
        on_cancel = function(reason)
          -- Cancelling a wait tears down only its entrance, not the source ask.
          local binding, async = request.binding, false
          while binding do async = async or binding.async_id ~= nil; binding = binding.ancestor end
          if async then detach(request) else request.cancel(reason) end
        end,
      }, function(value)
        if owner.active ~= request or not eligible(request) then return false end
        local selected = request.lease and request.lease.selected == true
        return request.submit(value, selected)
      end)
      if lease then request.lease, owner.active = lease, request end
      return
    end
  end
end

function M.refresh(root)
  if roots[root] then vim.schedule(function() pump(root) end) end
end

function M.bind_child(parent, child, ui, source)
  if type(parent) ~= "table" or type(child) ~= "table" then return end
  local ancestor = bindings[parent]
  local previous = source and bindings[source]
  local cancel_context = require("maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge").current()
  local binding = { parent = parent, root = ancestor and ancestor.root or parent, ancestor = ancestor,
    async_id = previous and previous.async_id or (cancel_context and cancel_context.async_id) }
  bindings[child] = binding
  local function close()
    if binding.closed then return end
    binding.closed = true
    local owner = roots[binding.root]
    if owner then
      for index = #owner.queue, 1, -1 do
        local request, ancestor = owner.queue[index], owner.queue[index].binding
        while ancestor and ancestor ~= binding do ancestor = ancestor.ancestor end
        if ancestor then
          detach(request)
          request.source.relay = nil
          table.remove(owner.queue, index)
        end
      end
    end
    M.refresh(binding.root)
  end
  if ui then require("maxa.interactions.chat.tools.display").on_terminal(ui, close) end
  if child.add_callback then child:add_callback("on_closed", close) end
  if parent.add_callback then parent:add_callback("on_closed", close) end
end

function M.enqueue(source, submit, cancel)
  local binding = bindings[source.chat]
  if not binding or binding.root == source.chat or not input.valid(binding.root) then return end
  local request = { source = source, binding = binding, root = binding.root, submit = submit, cancel = cancel }
  source.relay = request
  local owner = root_state(request.root)
  owner.queue[#owner.queue + 1] = request
  M.refresh(request.root)
end

function M.remove(source)
  local request = source.relay
  if request then
    source.relay = nil
    detach(request)
    local owner = roots[request.root]
    for index = #owner.queue, 1, -1 do
      if owner.queue[index] == request then table.remove(owner.queue, index) end
    end
    M.refresh(request.root)
  end
  M.refresh(source.chat)
end

-- One subscription per active blocking wait, including waits in ancestor children.
function M.attach_wait(chat, async_id)
  if type(chat) ~= "table" then return function() end end
  waits[chat] = waits[chat] or {}
  local owner = waits[chat]
  owner[async_id] = (owner[async_id] or 0) + 1
  for root in pairs(roots) do M.refresh(root) end
  local detached = false
  return function()
    if detached then return end
    detached = true
    owner[async_id] = math.max(0, (owner[async_id] or 1) - 1)
    for root, state in pairs(roots) do
      if state.active and not eligible(state.active) then detach(state.active) end
      M.refresh(root)
    end
  end
end

return M
