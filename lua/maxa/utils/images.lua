local M = {}

local Curl = require("plenary.curl")
local config = require("maxa.config")
local files_utils = require("maxa.utils.files")
local ui_utils = require("maxa.utils.ui")

---@class (private) MaxaAI.Image
---@field id string
---@field path string
---@field bufnr? integer
---@field base64? string
---@field mimetype? string

---Base64 encode the given image and generate the corresponding mimetype
---@param image MaxaAI.Image The image object containing the path and other metadata.
---@return MaxaAI.Image|string The base64 encoded image string
function M.encode_image(image)
  if image.base64 == nil then
    -- skip if already encoded
    local b64_content, b64_err = files_utils.base64_encode_file(image.path)
    if b64_err then
      return b64_err
    end

    image.base64 = b64_content
  end

  if not image.mimetype then
    image.mimetype = files_utils.get_mimetype(image.path)
  end

  return image
end

---Keep track of temp files, and GC them at `VimLeavePre`
---@type string[]
local temp_files = {}
local setup_complete = false

local function clear_temp_files()
  vim.iter(temp_files):each(function(p)
    (vim.uv or vim.loop).fs_unlink(p)
  end)
  temp_files = {}
end

---Register image lifecycle behavior explicitly and idempotently.
---@return boolean
function M.setup()
  if setup_complete then
    return true
  end
  local group = vim.api.nvim_create_augroup("maxa.ai.image", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = clear_temp_files,
    group = group,
    desc = "Clear temporary files.",
  })
  setup_complete = true
  return true
end

---Reset setup-owned state after an aborted runtime setup.
function M.reset_setup()
  pcall(vim.api.nvim_del_augroup_by_name, "maxa.ai.image")
  setup_complete = false
end

---@class (private) MaxaAI.Image.Preprocessor.Context
---@field chat_bufnr integer?

---@alias MaxaAI.Image.Preprocessor
--- | fun(source: string, ctx: MaxaAI.Image.Preprocessor.Context?, cb: fun(result: string|MaxaAI.Image)):nil
--- | fun(source: string, ctx: MaxaAI.Image.Preprocessor.Context?, cb: nil): string|MaxaAI.Image

---@type MaxaAI.Image.Preprocessor
function M.from_path(path, _, cb)
  local encoded = M.encode_image({ path = path, id = path, mimetype = files_utils.get_mimetype(path) })
  if type(cb) == "function" then
    return vim.schedule(function()
      ---@diagnostic disable-next-line: param-type-mismatch
      cb(encoded)
    end)
  end
  return encoded
end

---@type MaxaAI.Image.Preprocessor
function M.from_url(url, ctx, cb)
  ctx = ctx or {}

  local loc = vim.fn.tempname()
  temp_files[#temp_files + 1] = loc

  -- initialise with the default error message
  ---@type string|MaxaAI.Image
  local result = string.format("Could not get the image from %s.", url)

  local extmark_id = nil
  local ns = nil
  if ctx.chat_bufnr then
    ns = "maxa_ai_fetch_image_" .. tostring(ctx.chat_bufnr)
    vim.schedule(function()
      extmark_id = ui_utils.show_buffer_notification(
        ctx.chat_bufnr,
        { namespace = ns, text = "Fetching image from the given URL...", main_hl = "Comment" }
      )
    end)
  end
  local job = Curl.get(url, {
    insecure = config.adapters.http.opts.allow_insecure,
    raw = { "--noproxy", "*" },
    output = loc,
    callback = function(response)
      if extmark_id then
        extmark_id = nil
        vim.schedule(function()
          ui_utils.clear_notification(ctx.chat_bufnr, { namespace = ns })
        end)
      end
      if response.status ~= 200 then
        result = string.format(
          "Could not get the image from %s.\nHTTP Status: %d\nError: %s",
          url,
          response.status,
          response.body
        )
        if type(cb) == "function" then
          cb(result)
        end
      else
        local mimetype = nil
        if response.headers then
          for _, header_line in ipairs(response.headers) do
            local key, value = header_line:match("^([^:]+):%s*(.+)$")
            if key and value and key:lower() == "content-type" then
              mimetype = vim.trim(value:match("^([^;]+)")) -- Get part before any '; charset=...'
              break
            end
          end
        end

        result = M.encode_image({ mimetype = mimetype, path = loc, id = url })
        if type(cb) == "function" then
          vim.schedule(function()
            cb(result)
          end)
        end
      end
    end,
  })
  if cb == nil then
    job:sync()
    if extmark_id then
      extmark_id = nil
      vim.schedule(function()
        ui_utils.clear_notification(ctx.chat_bufnr, { namespace = ns })
      end)
    end
    return result
  end
end

return M
