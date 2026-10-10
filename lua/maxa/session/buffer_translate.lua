local M = {}

local DEFAULT_CONFIG = {
  allowed_extensions = { "md", "markdown", "txt", "rst", "adoc" },
  target_language = "简体中文",
  window = "vsplit",
  keymap = "<leader>at",
  force_keymap = "<leader>aT",
}

local config = vim.deepcopy(DEFAULT_CONFIG)
local result_buffers = {}
local last_result_buffer = nil
local status_bufnr = nil
local status_win = nil
local status_timer = nil
local status_spinner_timer = nil
local status_spinner_message = nil
local status_spinner_index = 1
local STATUS_SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function stop_status_spinner()
  if status_spinner_timer then
    status_spinner_timer:stop()
    status_spinner_timer:close()
    status_spinner_timer = nil
  end
  status_spinner_message = nil
  status_spinner_index = 1
end

local function close_status()
  stop_status_spinner()
  if status_timer then
    status_timer:stop()
    status_timer:close()
    status_timer = nil
  end
  if status_win and vim.api.nvim_win_is_valid(status_win) then
    pcall(vim.api.nvim_win_close, status_win, true)
  end
  if status_bufnr and vim.api.nvim_buf_is_valid(status_bufnr) then
    pcall(vim.api.nvim_buf_delete, status_bufnr, { force = true })
  end
  status_win = nil
  status_bufnr = nil
end

local function status_prefix(level)
  if level == vim.log.levels.ERROR then
    return "❌"
  end
  if level == vim.log.levels.WARN then
    return "⚠️"
  end
  return "⏳"
end

local function fit_status_line(message, width)
  message = tostring(message or "")
  if vim.fn.strdisplaywidth(message) <= width then
    return message
  end

  local ellipsis = "…"
  local result = ""
  local char_count = vim.fn.strchars(message)
  for index = 0, char_count - 1 do
    local next_result = result .. vim.fn.strcharpart(message, index, 1)
    if vim.fn.strdisplaywidth(next_result .. ellipsis) > width then
      break
    end
    result = next_result
  end
  return result .. ellipsis
end

local function render_status(message, level, opts)
  opts = opts or {}
  level = level or vim.log.levels.INFO
  local columns = math.max(vim.o.columns or 80, 20)
  local max_width = math.max(20, math.min(72, columns - 6))
  local line = tostring(opts.prefix or status_prefix(level)) .. " " .. tostring(message or "")
  local width = math.min(max_width, math.max(20, vim.fn.strdisplaywidth(line)))
  line = fit_status_line(line, width)

  if not status_bufnr or not vim.api.nvim_buf_is_valid(status_bufnr) then
    status_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[status_bufnr].buftype = "nofile"
    vim.bo[status_bufnr].bufhidden = "wipe"
    vim.bo[status_bufnr].swapfile = false
  end

  vim.bo[status_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(status_bufnr, 0, -1, false, { line })
  vim.bo[status_bufnr].modifiable = false

  local win_config = {
    relative = "editor",
    anchor = "SE",
    row = math.max(1, (vim.o.lines or 24) - (vim.o.cmdheight or 1) - 1),
    col = math.max(1, columns - 1),
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 60,
  }

  if status_win and vim.api.nvim_win_is_valid(status_win) then
    pcall(vim.api.nvim_win_set_config, status_win, win_config)
  else
    local ok, win = pcall(vim.api.nvim_open_win, status_bufnr, false, win_config)
    if ok then
      status_win = win
    else
      status_win = nil
      return nil
    end
  end

  if status_timer then
    status_timer:stop()
    status_timer:close()
    status_timer = nil
  end
  if opts.timeout and opts.timeout > 0 then
    status_timer = vim.loop.new_timer()
    status_timer:start(opts.timeout, 0, vim.schedule_wrap(close_status))
  end

  return { bufnr = status_bufnr, win = status_win }
end

local function show_status(message, level, opts)
  stop_status_spinner()
  return render_status(message, level, opts)
end

local function show_progress_status(message)
  stop_status_spinner()
  status_spinner_message = tostring(message or "")
  status_spinner_index = 1

  local function tick()
    if not status_spinner_message then
      return
    end
    local frame = STATUS_SPINNER_FRAMES[status_spinner_index]
    status_spinner_index = (status_spinner_index % #STATUS_SPINNER_FRAMES) + 1
    render_status(status_spinner_message, vim.log.levels.INFO, { prefix = frame })
  end

  tick()
  status_spinner_timer = vim.loop.new_timer()
  status_spinner_timer:start(120, 120, vim.schedule_wrap(tick))
  return { bufnr = status_bufnr, win = status_win }
end

local function notify(message, level, opts)
  local result = show_status(message, level, opts)

  if level == vim.log.levels.ERROR then
    local text = "[buffer_translate] " .. tostring(message or "")
    local emit = function()
      pcall(vim.notify, text, vim.log.levels.ERROR, { title = "Maxa Translate" })
    end
    if vim.in_fast_event() then
      vim.schedule(emit)
    else
      emit()
    end
  end

  return result
end

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function split_lines(text)
  if text == "" then
    return {}
  end
  return vim.split(text, "\n", { plain = true })
end

local function path_starts_with(path, prefix)
  path = vim.fs.normalize(path)
  prefix = vim.fs.normalize(prefix):gsub("/+$", "")
  return path == prefix or path:sub(1, #prefix + 1) == prefix .. "/"
end

local function relpath(root, path)
  root = vim.fs.normalize(root):gsub("/+$", "")
  path = vim.fs.normalize(path)
  if vim.fs.relpath then
    local relative = vim.fs.relpath(root, path)
    if relative then
      return relative
    end
  end
  if path == root then
    return "."
  end
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return nil
end

local function extension(path)
  local ext = tostring(path or ""):match("%.([^./\\]+)$")
  return ext and ext:lower() or ""
end

local function allowed_extension(path, allowed_extensions)
  local ext = extension(path)
  for _, allowed in ipairs(allowed_extensions or {}) do
    if ext == tostring(allowed):lower():gsub("^%.", "") then
      return true
    end
  end
  return false
end

function M.normalize_semantic_content(text)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = split_lines(text)
  for index, line in ipairs(lines) do
    lines[index] = line:gsub("[ \t]+$", "")
  end
  text = table.concat(lines, "\n")
  text = trim(text)
  repeat
    local next_text = text:gsub("\n\n\n+", "\n\n")
    if next_text == text then
      break
    end
    text = next_text
  until false
  return text
end

function M.semantic_hash(text)
  return vim.fn.sha256(M.normalize_semantic_content(text))
end

function M.cache_key(relative_path, semantic_hash, target_language)
  return vim.fn.sha256(table.concat({ relative_path, semantic_hash, target_language }, "\n"))
end

local function cache_dir(root)
  return vim.fs.joinpath(root, ".maxa", "translate-cache")
end

local function cache_path(root, key)
  return vim.fs.joinpath(cache_dir(root), key .. ".md")
end

local function read_buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

function M.resolve_source(bufnr, opts)
  opts = opts or config
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "当前 buffer 无效"
  end

  local buftype = vim.bo[bufnr].buftype
  if buftype ~= "" then
    return nil, "只允许翻译普通文件 buffer，当前 buftype=" .. buftype
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil, "当前 buffer 没有文件路径，不能翻译临时 buffer"
  end

  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "当前 buffer 不是可读取的真实文件"
  end

  local root = vim.fs.root(bufnr, { ".maxa" })
  if not root then
    return nil, "当前文件不在包含 .maxa 的项目中"
  end
  root = vim.fs.normalize(root)

  if not path_starts_with(path, root) then
    return nil, "当前文件不在项目根目录下"
  end

  local translate_cache_dir = cache_dir(root)
  if path_starts_with(path, translate_cache_dir) then
    return nil, "缓存目录中的翻译结果不能作为源文档翻译"
  end

  if not allowed_extension(path, opts.allowed_extensions) then
    return nil, "当前文件后缀不在允许翻译列表中: ." .. extension(path)
  end

  local relative = relpath(root, path)
  if not relative then
    return nil, "无法计算当前文件的项目相对路径"
  end

  return {
    bufnr = bufnr,
    path = path,
    root = root,
    relative_path = relative,
    filetype = vim.bo[bufnr].filetype,
  }
end

local function is_result_buffer(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].maxa_translate_key ~= nil
end

local function cleanup_result_buffer_index(bufnr)
  for indexed_key, indexed_buf in pairs(result_buffers) do
    if indexed_buf == bufnr or not vim.api.nvim_buf_is_valid(indexed_buf) then
      result_buffers[indexed_key] = nil
    end
  end
  if last_result_buffer and not vim.api.nvim_buf_is_valid(last_result_buffer) then
    last_result_buffer = nil
  end
end

local function find_result_window(key)
  local indexed = result_buffers[key]
  if indexed and vim.api.nvim_buf_is_valid(indexed) and vim.b[indexed].maxa_translate_key == key then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == indexed then
        return win, indexed
      end
    end
  elseif indexed then
    result_buffers[key] = nil
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].maxa_translate_key == key then
      result_buffers[key] = bufnr
      last_result_buffer = bufnr
      return win, bufnr
    end
  end

  return nil, nil
end

local function find_any_result_window()
  if last_result_buffer and is_result_buffer(last_result_buffer) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == last_result_buffer then
        return win, last_result_buffer
      end
    end
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    if is_result_buffer(bufnr) then
      last_result_buffer = bufnr
      return win, bufnr
    end
  end

  return nil, nil
end

local function set_result_buffer_name(bufnr, source, key)
  -- Explorer follows buffer names as file paths; keep this scratch name in one path segment.
  local label = source.relative_path:gsub("[/\\]", " › ")
  local name = "Maxa Translate: " .. label .. " [" .. key:sub(1, 8) .. "]"
  pcall(vim.api.nvim_buf_set_name, bufnr, name)
end

local function close_result_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  cleanup_result_buffer_index(bufnr)
  if last_result_buffer == bufnr then
    last_result_buffer = nil
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

local function set_result_keymaps(bufnr)
  vim.keymap.set("n", "q", function()
    close_result_buffer(bufnr)
  end, {
    buffer = bufnr,
    desc = "Close Maxa translate result",
    nowait = true,
    silent = true,
  })
end

local function set_scratch_content(bufnr, source, content, key)
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, split_lines(content))
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  cleanup_result_buffer_index(bufnr)
  vim.b[bufnr].maxa_translate_key = key
  vim.b[bufnr].maxa_translate_source_path = source.path
  vim.b[bufnr].maxa_translate_relative_path = source.relative_path
  result_buffers[key] = bufnr
  last_result_buffer = bufnr
  set_result_keymaps(bufnr)
end

local function open_scratch(source, content, key)
  local existing_win, existing_buf = find_result_window(key)
  if not existing_win then
    existing_win, existing_buf = find_any_result_window()
  end
  if existing_win and existing_buf then
    vim.api.nvim_set_current_win(existing_win)
    set_result_buffer_name(existing_buf, source, key)
    set_scratch_content(existing_buf, source, content, key)
    return existing_buf, true
  end

  if config.window == "split" then
    vim.cmd("split")
  else
    vim.cmd("vsplit")
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, bufnr)

  set_result_buffer_name(bufnr, source, key)

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = source.filetype ~= "" and source.filetype or "markdown"

  set_scratch_content(bufnr, source, content, key)
  return bufnr, false
end

local function write_cache(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, err = pcall(vim.fn.writefile, split_lines(content), path)
  if not ok then
    return false, err
  end
  return true
end

local function read_cache(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  return table.concat(lines, "\n")
end

local function ensure_maxa_ai_loaded()
  local ok = pcall(require, "maxa.config")
  if ok then
    return true
  end


  local retry_ok, err = pcall(require, "maxa.config")
  if not retry_ok then
    return false, err
  end
  return true
end

local function apply_adapter_overrides(adapter, model, temperature)
  if model == nil and temperature == nil then
    return adapter
  end

  if type(adapter) == "table" then
    adapter = vim.deepcopy(adapter)
    if model ~= nil then
      adapter.model = model
    end
    if temperature ~= nil then
      adapter.temperature = temperature
    end
    return adapter
  end

  local spec = { name = adapter }
  if model ~= nil then
    spec.model = model
  end
  if temperature ~= nil then
    spec.temperature = temperature
  end
  return spec
end

local function apply_thinking_mode(adapter, thinking_mode)
  if thinking_mode == nil then
    return adapter
  end
  if type(thinking_mode) ~= "string" or thinking_mode == "" then
    return nil, "translate thinking_mode 必须是非空字符串"
  end
  local reasoning_schema = adapter and adapter.schema and adapter.schema["reasoning.effort"]
  if type(reasoning_schema) ~= "table" then
    return nil, "translate adapter 不支持 thinking_mode（缺少 reasoning.effort schema）"
  end
  if type(reasoning_schema.choices) == "table" then
    local supported = false
    for key, choice in pairs(reasoning_schema.choices) do
      local value = type(key) == "number" and choice or key
      if value == thinking_mode then
        supported = true
        break
      end
    end
    if not supported then
      return nil, "translate thinking_mode 不受 adapter 支持: " .. thinking_mode
    end
  end
  reasoning_schema.default = thinking_mode
  return adapter
end
local function translation_adapter_config(opts)
  opts = opts or {}

  -- Backward compatibility: callers may still pass adapter/model to setup(),
  -- but defaults now live in util.mcphub.config.adapters.translate.
  if opts.adapter and opts.adapter ~= "" then
    return {
      adapter = opts.adapter,
      model = opts.model,
      temperature = opts.temperature,
      thinking_mode = opts.thinking_mode,
      inherit = opts.adapter == "inherit",
      source = "buffer_translate.setup",
    }
  end

  local ok, mcp_config = pcall(require, "maxa.mcphub.native_servers.config")
  if not ok then
    return nil, "无法加载 util.mcphub.config: " .. tostring(mcp_config)
  end
  if type(mcp_config.get_adapter) ~= "function" then
    return nil, "maxa.mcphub.native_servers.config 缺少 get_adapter()"
  end

  local preset, err = mcp_config.get_internal_adapter("translate")
  if not preset then
    return nil, "无法读取 translate adapter 配置: " .. tostring(err)
  end
  return preset, nil
end

local function current_adapter_spec(opts)
  local cc_config = require("maxa.config")
  local adapter_cfg, cfg_err = translation_adapter_config(opts)
  if not adapter_cfg then
    return nil, cfg_err
  end

  local adapter
  if adapter_cfg.inherit or adapter_cfg.adapter == "inherit" then
    adapter = vim.deepcopy(cc_config.interactions.chat.adapter)
  else
    adapter = adapter_cfg.adapter
  end

  local adapter_spec = apply_adapter_overrides(adapter, adapter_cfg.model, adapter_cfg.temperature)
  return adapter_spec, nil, adapter_cfg.thinking_mode
end

local function ensure_model_choice(adapter)
  local model_schema = adapter and adapter.schema and adapter.schema.model
  if type(model_schema) ~= "table" then
    return
  end

  local model = adapter.model and adapter.model.name or model_schema.default
  if type(model) ~= "string" or model == "" then
    return
  end

  if type(model_schema.choices) ~= "table" then
    model_schema.choices = {}
  end
  if type(model_schema.choices[model]) ~= "table" then
    model_schema.choices[model] = { opts = {} }
  elseif type(model_schema.choices[model].opts) ~= "table" then
    model_schema.choices[model].opts = {}
  end

  if type(adapter.model) == "table" and adapter.model.name == model and type(adapter.model.opts) ~= "table" then
    adapter.model.opts = model_schema.choices[model].opts
  end
end

local function resolve_translation_adapter(opts)
  local loaded, load_err = ensure_maxa_ai_loaded()
  if not loaded then
    return nil, "MaxaAI 未加载，无法翻译: " .. tostring(load_err)
  end

  local adapters = require("maxa.adapters")
  local adapter_spec, spec_err, thinking_mode = current_adapter_spec(opts)
  if not adapter_spec then
    return nil, spec_err
  end
  local resolved = adapters.resolve(adapter_spec)
  if not resolved then
    return nil, "无法解析 Maxa AI adapter"
  end
  if resolved.type ~= "http" then
    return nil, "MaxaTranslateBuffer 只支持 MaxaAI HTTP adapter"
  end
  resolved, spec_err = apply_thinking_mode(resolved, thinking_mode)
  if not resolved then
    return nil, spec_err
  end
  local adapter = resolved
  adapter:map_schema_to_params(require("maxa.schema").get_default(adapter))
  ensure_model_choice(adapter)
  if adapter.opts then
    adapter.opts.stream = true
  else
    adapter.opts = { stream = true }
  end
  return adapter
end

local function translation_messages(source, text, target_language)
  local cc_config = require("maxa.config")
  return {
    {
      role = cc_config.constants.SYSTEM_ROLE,
      content = table.concat({
        "You are a translation engine for project documents.",
        "Translate the provided document into " .. target_language .. ".",
        "Return only the translated document.",
        "Do not add explanations, summaries, prefaces, or code fences around the whole answer.",
        "Preserve Markdown structure, headings, lists, tables, links, inline code, and fenced code blocks.",
        "Do not translate code identifiers, URLs, file paths, command names, or markup syntax.",
      }, "\n"),
    },
    {
      role = cc_config.constants.USER_ROLE,
      content = table.concat({
        "Target language: " .. target_language,
        "Source path: " .. source.relative_path,
        "",
        "Document:",
        text,
      }, "\n"),
    },
  }
end

local function collect_responses_output_text(output)
  if type(output) ~= "table" then
    return nil
  end

  local chunks = {}
  for _, item in ipairs(output) do
    if type(item) == "table" and item.type == "message" and type(item.content) == "table" then
      for _, block in ipairs(item.content) do
        if type(block) == "table" then
          local text = block.text or block.output_text
          if (block.type == "output_text" or block.type == "text") and type(text) == "string" then
            table.insert(chunks, text)
          end
        end
      end
    end
  end

  if #chunks == 0 then
    return nil
  end
  return trim(table.concat(chunks, "\n"))
end

local function extract_translation(result)
  if type(result) == "string" then
    local parsed_ok, parsed = pcall(vim.json.decode, result)
    if parsed_ok then
      return extract_translation(parsed)
    end
    return trim(result)
  end
  if type(result) ~= "table" then
    return nil
  end

  if type(result.output) == "string" then
    local content = trim(result.output)
    if content ~= "" then
      return content
    end
  end
  if result.output and type(result.output.content) == "string" then
    local content = trim(result.output.content)
    if content ~= "" then
      return content
    end
  end
  if type(result.content) == "string" then
    local content = trim(result.content)
    if content ~= "" then
      return content
    end
  end
  if type(result.output_text) == "string" then
    local content = trim(result.output_text)
    if content ~= "" then
      return content
    end
  end

  local responses_text = collect_responses_output_text(result.output)
  if responses_text and responses_text ~= "" then
    return responses_text
  end

  if result.response then
    responses_text = collect_responses_output_text(result.response.output)
    if responses_text and responses_text ~= "" then
      return responses_text
    end
  end

  return nil
end

function M.translate_current_buffer(opts)
  opts = opts or {}
  local source, source_err = M.resolve_source(vim.api.nvim_get_current_buf(), config)
  if not source then
    notify(source_err, vim.log.levels.ERROR, { timeout = 4000 })
    return
  end

  local text = read_buffer_text(source.bufnr)
  local semantic_hash = M.semantic_hash(text)
  local key = M.cache_key(source.relative_path, semantic_hash, config.target_language)
  local path = cache_path(source.root, key)

  local cached = not opts.force and read_cache(path) or nil
  if cached then
    local _, reused = open_scratch(source, cached, key)
    notify((reused and "已复用翻译窗口: " or "已复用翻译缓存: ") .. source.relative_path, vim.log.levels.INFO, { timeout = 1200 })
    return
  end

  local adapter, err = resolve_translation_adapter(config)
  if not adapter then
    notify(err, vim.log.levels.ERROR, { timeout = 4000 })
    return
  end

  local adapters = require("maxa.adapters")
  local http = require("maxa.http")
  local stream_output = {}
  local stream_error = false
  local messages = translation_messages(source, text, config.target_language)
  local payload = {
    messages = adapter:map_roles(vim.deepcopy(messages)),
  }

  local function finish_translation(result)
    vim.schedule(function()
      local translation = #stream_output > 0 and trim(table.concat(stream_output, "")) or extract_translation(result)
      if not translation or translation == "" then
        notify("翻译失败：LLM 未返回可用译文", vim.log.levels.ERROR, { timeout = 5000 })
        return
      end
      local ok, write_err = write_cache(path, translation)
      if not ok then
        notify("写入翻译缓存失败: " .. tostring(write_err), vim.log.levels.ERROR, { timeout = 5000 })
        return
      end
      local _, reused = open_scratch(source, translation, key)
      notify(
        (reused and "翻译完成并已更新窗口: " or "翻译完成并已写入缓存: ") .. source.relative_path,
        vim.log.levels.INFO,
        { timeout = 1600 }
      )
    end)
  end

  show_progress_status("正在翻译: " .. source.relative_path)
  local send_ok, send_err = pcall(function()
    http.new({ adapter = adapter }):send(payload, {
      on_chunk = function(data)
        if not data or data == "" then
          return
        end
        local result = adapters.call_handler(adapter, "parse_chat", data)
        if result and result.status == "success" and result.output then
          local content = type(result.output) == "table" and result.output.content or result.output
          if type(content) == "string" and content ~= "" then
            table.insert(stream_output, content)
          end
        end
      end,
      on_done = function(response)
        if stream_error then
          return
        end
        finish_translation(response)
      end,
      on_error = function(request_err)
        stream_error = true
        vim.schedule(function()
          local message = request_err and (request_err.stderr or request_err.message) or "unknown error"
          notify("翻译请求失败: " .. tostring(message), vim.log.levels.ERROR, { timeout = 5000 })
        end)
      end,
      bufnr = source.bufnr,
      interaction = "background",
    })
  end)
  if not send_ok then
    notify("翻译请求启动失败: " .. tostring(send_err), vim.log.levels.ERROR, { timeout = 5000 })
  end
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_CONFIG), opts or {})
  vim.api.nvim_create_user_command("MaxaTranslateBuffer", function(command_opts)
    M.translate_current_buffer({ force = command_opts.bang })
  end, {
    bang = true,
    desc = "Translate current project document buffer with Maxa AI and open cached result",
    force = true,
  })

  if config.keymap and config.keymap ~= "" then
    vim.keymap.set("n", config.keymap, "<Cmd>MaxaTranslateBuffer<CR>", {
      desc = "Maxa: Translate current buffer",
      silent = true,
    })
  end

  if config.force_keymap and config.force_keymap ~= "" then
    vim.keymap.set("n", config.force_keymap, "<Cmd>MaxaTranslateBuffer!<CR>", {
      desc = "Maxa: Force translate current buffer",
      silent = true,
    })
  end
end

M._private = {
  allowed_extension = allowed_extension,
  cache_dir = cache_dir,
  cache_path = cache_path,
  extension = extension,
  fit_status_line = fit_status_line,
  extract_translation = extract_translation,
  close_result_buffer = close_result_buffer,
  close_status = close_status,
  apply_thinking_mode = apply_thinking_mode,
  ensure_model_choice = ensure_model_choice,
  find_any_result_window = find_any_result_window,
  find_result_window = find_result_window,
  relpath = relpath,
  notify = notify,
  show_progress_status = show_progress_status,
  show_status = show_status,
  stop_status_spinner = stop_status_spinner,
}

return M
