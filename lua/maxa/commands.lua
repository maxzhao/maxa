---@class MaxaAI.Command
---@field cmd string
---@field callback fun(args:table)
---@field opts MaxaAI.Command.Opts

---@class MaxaAI.Command.Opts:table
---@field desc string

local maxa_ai = require("maxa")
local config = require("maxa.config")

local _cached_adapters = nil

---Get the available HTTP adapters from the config
---@return string[]
local function get_adapters()
  if not _cached_adapters then
    _cached_adapters = vim
      .iter(config.adapters.http)
      :filter(function(k, _)
        return k ~= "opts"
      end)
      :map(function(k, _)
        return k
      end)
      :totable()
  end
  return _cached_adapters
end

---@type MaxaAI.Command[]
return {
  {
    cmd = "Maxa",
    callback = function(opts)
      local params = {}
      local prompt = {}
      local subcommand = nil

      for _, arg in ipairs(opts.fargs) do
        local key, value = arg:match("^(%w+)=(.+)$")
        if key and value then
          params[key] = value
        elseif arg:lower() == "toggle" or arg:lower() == "add" or arg:lower() == "refreshcache" then
          subcommand = arg:lower()
        else
          table.insert(prompt, arg)
        end
      end

      opts.params = params
      opts.subcommand = subcommand

      if #prompt > 0 then
        opts.user_prompt = table.concat(prompt, " ")
        opts.args = opts.user_prompt
      end

      maxa_ai.chat(opts)
    end,
    opts = {
      desc = "Work with a Maxa AI chat buffer",
      range = true,
      nargs = "*",
      complete = function(arg_lead, cmdline, _cursor_pos)
        local param_key = arg_lead:match("^(%w+)=$")
        if param_key == "adapter" then
          return get_adapters()
        elseif param_key == "model" then
          local adapter_name = cmdline:match("adapter=(%S+)")
          if adapter_name then
            local adapter_config = config.adapters.http[adapter_name]
            if adapter_config then
              local ok, adapter = pcall(require("maxa.adapters").resolve, adapter_config)
              if ok and adapter and adapter.schema and adapter.schema.model and adapter.schema.model.choices then
                local choices = adapter.schema.model.choices
                if type(choices) == "function" then
                  local ok_fn, result = pcall(choices, adapter, { async = false })
                  if ok_fn and result then
                    choices = result
                  else
                    return {}
                  end
                end
                if type(choices) == "table" then
                  return vim.islist(choices) and choices or vim.tbl_keys(choices)
                end
              end
            end
          end
          return {}
        end

        if cmdline:match("^['<,'>]*Maxa[!]*%s+$") or arg_lead == "" then
          local completions = {
            "adapter=",
            "model=",
            "Toggle",
            "Add",
            "RefreshCache",
          }
          return vim
            .iter(completions)
            :filter(function(key)
              return key:find(vim.pesc(arg_lead), 1, true) == 1
            end)
            :totable()
        end

        return {}
      end,
    },
  },
}
