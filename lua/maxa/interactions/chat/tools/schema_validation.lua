-- Shared, bounded JSON Schema checks for raw tool arguments.
-- Validation never coerces arguments, injects defaults, or resolves remote refs.
local M = {}
local islist = vim.islist or vim.tbl_islist
local annotations = {
  description=true, title=true, default=true, examples=true, deprecated=true,
  readOnly=true, writeOnly=true, ["$schema"]=true, ["$id"]=true, ["$comment"]=true,
}
local assertions = {
  type=true, properties=true, required=true, additionalProperties=true, items=true,
  minItems=true, maxItems=true, uniqueItems=true, minLength=true, maxLength=true,
  minimum=true, maximum=true, exclusiveMinimum=true, exclusiveMaximum=true, multipleOf=true,
  enum=true, const=true, anyOf=true, oneOf=true, allOf=true, ["not"]=true,
  ["$ref"]=true, ["$defs"]=true, definitions=true, pattern=true,
  minProperties=true, maxProperties=true,
}
local function null(value) return value == vim.NIL end
local function array(value)
  return type(value)=="table" and islist(value) and getmetatable(value) ~= vim._empty_dict_mt
end
local function object(value, root)
  return type(value)=="table" and (not array(value) or (root and next(value)==nil))
end
local function kind(value, root)
  if null(value) then return "null" end
  if type(value)=="table" then return object(value,root) and "object" or "array" end
  return type(value)
end
local function matches_type(value, expected, root)
  if expected=="integer" then return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge and value%1==0 end
  if expected=="number" then return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge end
  return kind(value,root)==expected
end
local function error_at(path, keyword, message, schema_error)
  return {path=path,keyword=keyword,message=message,schema_error=schema_error==true}
end
local function resolve(root, ref)
  if ref=="#" then return root end
  if type(ref)~="string" or ref:sub(1,2)~="#/" then return nil end
  local node=root
  for token in ref:sub(3):gmatch("[^/]+") do
    token=token:gsub("~1","/"):gsub("~0","~")
    if type(node)~="table" then return nil end
    node=node[token]
  end
  return node
end
local function regex(pattern)
  if type(pattern)~="string" then return nil,"pattern must be a string" end
  -- These native regex constructs have no compatible Vim equivalent here.
  if pattern:find("(?",1,true) or pattern:find("[+*?}]%?") then
    return nil,"lookaround, special groups and lazy quantifiers are unsupported"
  end
  local converted={}
  local index=1
  while index<=#pattern do
    local char=pattern:sub(index,index)
    if char=="\\" then
      local escaped=pattern:sub(index+1,index+1)
      if escaped=="d" then converted[#converted+1]="[0-9]"
      elseif escaped=="w" then converted[#converted+1]="[A-Za-z0-9_]"
      elseif escaped:match("[%a%d]") or escaped=="" then return nil,"unsupported pattern escape \\"..escaped
      else converted[#converted+1]="\\"..escaped end
      index=index+2
    else
      if char:find("[<>=%%~&@]") then char="\\"..char end
      converted[#converted+1]=char
      index=index+1
    end
  end
  local ok, compiled=pcall(vim.regex,"\\C\\v"..table.concat(converted))
  if not ok then return nil,"invalid or unsupported pattern" end
  return compiled
end

function M.format_error(err)
  return string.format("%s at %s (%s): %s",err.schema_error and "Unsupported/invalid tool schema" or "Invalid tool arguments",err.path,err.keyword,err.message)
end

function M.validate(schema, value, opts)
  opts=opts or {}
  local root=schema
  local nodes=0
  local visit
  visit=function(s,v,path,depth,is_root)
    nodes=nodes+1
    if depth>64 or nodes>100000 then return error_at(path,"limit","validation depth/node budget exceeded",true) end
    if s==true then return nil end
    if s==false then return error_at(path,"false","value is not permitted") end
    if type(s)~="table" then return error_at(path,"schema","schema must be an object or boolean",true) end
    for key in pairs(s) do
      if not annotations[key] and not assertions[key] then return error_at(path,key,"unsupported schema keyword",true) end
    end
    if s.required and (type(s.required) ~= "table" or not islist(s.required)) then
      return error_at(path,"required","required must be a string array",true)
    end
    for _, key in ipairs(s.required or {}) do
      if type(key) ~= "string" then return error_at(path,"required","required entries must be strings",true) end
    end
    if s.properties and type(s.properties) ~= "table" then return error_at(path,"properties","properties must be an object",true) end
    if s.additionalProperties ~= nil and type(s.additionalProperties) ~= "boolean" and type(s.additionalProperties) ~= "table" then
      return error_at(path,"additionalProperties","must be a boolean or schema",true)
    end
    for _, key in ipairs({"minimum","maximum","exclusiveMinimum","exclusiveMaximum","multipleOf","minItems","maxItems","minLength","maxLength","minProperties","maxProperties"}) do
      if s[key] ~= nil and (type(s[key]) ~= "number" or s[key] ~= s[key] or math.abs(s[key]) == math.huge) then
        return error_at(path,key,"constraint must be a finite number",true)
      end
    end
    for _, key in ipairs({"enum","anyOf","oneOf","allOf"}) do
      if s[key] ~= nil and (type(s[key]) ~= "table" or not islist(s[key]) or #s[key] == 0) then
        return error_at(path,key,"constraint must be a nonempty array",true)
      end
    end
    if s["$ref"] then
      local target=resolve(root,s["$ref"])
      if target==nil then return error_at(path,"$ref","only resolvable local JSON Pointer refs are supported",true) end
      local err=visit(target,v,path,depth+1,is_root)
      if err then return err end
    end
    if s.type then
      local types=type(s.type)=="table" and s.type or {s.type}
      local valid=false
      for _,expected in ipairs(types) do
        if not vim.tbl_contains({"null","object","array","string","number","integer","boolean"},expected) then
          return error_at(path,"type","unsupported schema type",true)
        end
        valid=valid or matches_type(v,expected,is_root)
      end
      if not valid then return error_at(path,"type","expected "..table.concat(types,"|")..", got "..kind(v,is_root)) end
    end
    if s.enum then
      local valid=false
      for _,candidate in ipairs(s.enum) do valid=valid or vim.deep_equal(v,candidate) end
      if not valid then return error_at(path,"enum","value is not in the declared enum") end
    end
    if s.const~=nil and not vim.deep_equal(v,s.const) then return error_at(path,"const","value differs from const") end
    for _,keyword in ipairs({"anyOf","oneOf","allOf"}) do
      if s[keyword] then
        local success=0
        for _,branch in ipairs(s[keyword]) do
          local err=visit(branch,v,path,depth+1,is_root)
          if err and err.schema_error then return err end
          if not err then success=success+1 end
        end
        if (keyword=="anyOf" and success==0) or (keyword=="oneOf" and success~=1)
          or (keyword=="allOf" and success~=#s[keyword]) then
          return error_at(path,keyword,"value does not satisfy the declared alternatives")
        end
      end
    end
    if s["not"] then
      local err=visit(s["not"],v,path,depth+1,is_root)
      if err and err.schema_error then return err end
      if not err then return error_at(path,"not","value matches a forbidden schema") end
    end
    if object(v,is_root) then
      for _,key in ipairs(s.required or {}) do
        if rawget(v,key)==nil then return error_at(path.."."..key,"required","required property is missing") end
      end
      local count=0
      for key,child in pairs(v) do
        count=count+1
        if type(key)~="string" then return error_at(path,"properties","object keys must be strings") end
        local child_schema=(s.properties or {})[key]
        if child_schema==nil then child_schema=s.additionalProperties end
        if child_schema==false then return error_at(path.."."..key,"additionalProperties","unknown property") end
        if type(child_schema)=="table" or type(child_schema)=="boolean" then
          local err=visit(child_schema,child,path.."."..key,depth+1,false)
          if err then return err end
        end
      end
      if s.minProperties and count<s.minProperties then return error_at(path,"minProperties","too few properties") end
      if s.maxProperties and count>s.maxProperties then return error_at(path,"maxProperties","too many properties") end
    elseif array(v) then
      if s.minItems and #v<s.minItems then return error_at(path,"minItems","too few array items") end
      if s.maxItems and #v>s.maxItems then return error_at(path,"maxItems","too many array items") end
      for i,child in ipairs(v) do
        if s.items~=nil then
          local err=visit(s.items,child,path.."["..i.."]",depth+1,false)
          if err then return err end
        end
        if s.uniqueItems then
          for j=1,i-1 do
            nodes=nodes+1
            if nodes>100000 then return error_at(path,"limit","validation node budget exceeded",true) end
            if vim.deep_equal(v[j],child) then return error_at(path.."["..i.."]","uniqueItems","duplicate item") end
          end
        end
      end
    elseif type(v)=="string" then
      local length=vim.fn.strchars(v)
      if s.minLength and length<s.minLength then return error_at(path,"minLength","string is too short") end
      if s.maxLength and length>s.maxLength then return error_at(path,"maxLength","string is too long") end
      if s.pattern then
        local compiled,err=regex(s.pattern)
        if not compiled then return error_at(path,"pattern",err,true) end
        if compiled:match_str(v)==nil then return error_at(path,"pattern","string does not match pattern") end
      end
    end
    if type(v)=="number" then
      if v~=v or v==math.huge or v==-math.huge then return error_at(path,"number","number must be finite") end
      if s.minimum and v<s.minimum then return error_at(path,"minimum","number below minimum") end
      if s.maximum and v>s.maximum then return error_at(path,"maximum","number above maximum") end
      if s.exclusiveMinimum and v<=s.exclusiveMinimum then return error_at(path,"exclusiveMinimum","number must exceed boundary") end
      if s.exclusiveMaximum and v>=s.exclusiveMaximum then return error_at(path,"exclusiveMaximum","number must be below boundary") end
      if s.multipleOf then
        if type(s.multipleOf)~="number" or s.multipleOf<=0 then return error_at(path,"multipleOf","invalid divisor",true) end
        local quotient=v/s.multipleOf
        if math.abs(quotient-math.floor(quotient+0.5))>1e-9 then return error_at(path,"multipleOf","number is not a multiple") end
      end
    end
    return nil
  end
  local ok,err=pcall(visit,schema,value,"$",0,opts.object_root==true)
  if not ok then return false,error_at("$","schema","invalid schema or argument structure",true) end
  return err==nil,err
end

return M
