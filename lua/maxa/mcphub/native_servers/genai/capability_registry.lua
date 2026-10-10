-- Lightweight registry for explicit GenAI capabilities declared by gateway adapters.
local M = {}
local declarations = {}
local ALLOWED = { image = true, tts = true, video = true }

local function deepcopy(value)
  return vim.deepcopy(value)
end

local function normalize(name, formatted_name, genai)
  if type(name) ~= "string" or name == "" then return nil, "adapter name is required" end
  if genai == nil then return { name = name, formatted_name = formatted_name, capabilities = {} } end
  if type(genai) ~= "table" then return nil, "genai must be a table" end
  local capabilities = {}
  for capability, config in pairs(genai) do
    if not ALLOWED[capability] then return nil, "unsupported genai capability: " .. tostring(capability) end
    if type(config) ~= "table" then return nil, "genai." .. capability .. " must be a table" end
    capabilities[capability] = deepcopy(config)
  end
  return { name = name, formatted_name = formatted_name or name, capabilities = capabilities }
end

function M.register(name, formatted_name, genai)
  local declaration, err = normalize(name, formatted_name, genai)
  if not declaration then return false, err end
  declarations[name] = declaration
  return true
end

function M.get(name)
  local value = declarations[name]
  return value and deepcopy(value) or nil
end

function M.list(capability)
  if not ALLOWED[capability] then return {} end
  local result = {}
  for name, declaration in pairs(declarations) do
    if declaration.capabilities[capability] then
      table.insert(result, { name = name, formatted_name = declaration.formatted_name })
    end
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

function M.clear_for_test()
  declarations = {}
end

return M
