-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/schema_validation_test.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local check=require('maxa.interactions.chat.tools.schema_validation')
local function valid(schema,value)
 local ok,err=check.validate(schema,value)
 assert(ok,err and check.format_error(err))
end
local function reject(schema,value,key)
 local ok,err=check.validate(schema,value)
 assert(not ok and err.keyword==key,err and check.format_error(err))
end
local schema={type='object',additionalProperties=false,properties={
 title={type='string',minLength=1},
 optional={type={'string','null'}},
 items={type='array',minItems=1,maxItems=2,items={type='object',additionalProperties=false,
   properties={value={type='integer',minimum=1,maximum=5}},required={'value'}}},
},required={'title'}}
valid(schema,vim.json.decode('{"title":"ok"}'))
valid(schema,vim.json.decode('{"title":"ok","optional":null,"items":[{"value":2}]}'))
reject(schema,vim.json.decode('{"title":"ok","unknown":null}'),'additionalProperties')
reject(schema,vim.json.decode('{"title":null}'),'type')
reject(schema,vim.json.decode('{"title":"ok","items":[{"value":2.5}]}'),'type')
reject(schema,vim.json.decode('{"title":"ok","items":[{"value":8}]}'),'maximum')
reject({type='object'},vim.json.decode('[]'),'type')
reject({type='array'},vim.json.decode('{}'),'type')
valid({type='string',maxLength=1},'界')
reject({type='string',maxLength=1},'界界','maxLength')
valid({anyOf={{type='string'},{type='number'}}},3)
reject({oneOf={{type='number'},{type='integer'}}},3,'oneOf')
valid({type='object',properties={x={['$ref']='#/$defs/value'}},['$defs']={value={type='integer'}}},vim.json.decode('{"x":3}'))
reject({['$ref']='https://invalid.example/schema'},3,'$ref')
reject({type='string',format='unknown-format'},'x','format')
valid({type='string',pattern='^(auto|[1-9][0-9]*x[1-9][0-9]*)$'},'1024x512')
valid({type='string',pattern='^(auto|[1-9][0-9]*x[1-9][0-9]*)$'},'auto')
reject({type='string',pattern='^(auto|[1-9][0-9]*x[1-9][0-9]*)$'},'0x1','pattern')
reject({type='string',pattern='(?=x)'},'x','pattern')
reject({type='array',uniqueItems=true},vim.json.decode('[1,1]'),'uniqueItems')

-- The shared seam validates raw args, then calls prepare exactly once, without
-- applying the public raw schema again to prepare's internal representation.
local data=vim.fn.stdpath('data')..'/lazy/plenary.nvim'
vim.opt.runtimepath:append(data)
local adapter=require('maxa.interactions.chat.tools.builtin.runtime.adapter')
local count,ran=0,0
local definition={name='fixture',inputSchema={type='object',properties={value={type='string'}},required={'value'}},
 prepare=function(ctx) count=count+1;return {value=tonumber(ctx.params.value)} end,
 run=function(ctx,res) ran=ran+1;assert(ctx.params.value==3);return res:text('prepared'):send() end}
local result
adapter.invoke(definition,{params={value='3'}},function(r) result=r end)
assert(result.ok and count==1 and ran==1)
adapter.invoke(definition,{params={value=3}},function(r) result=r end)
assert(not result.ok and count==1 and ran==1)
local prepared=assert(adapter.prepare(definition,{params={value='3'}}))
assert(count==2)
adapter.invoke(definition,prepared,function(r) result=r end,true)
assert(result.ok and count==2 and ran==2)
local bad={name='bad',inputSchema={type='object'},prepare=function() error('bad prepare') end,
 run=function() error('must not execute') end}
adapter.invoke(bad,{params=vim.empty_dict()},function(r) result=r end)
assert(not result.ok and result.error:find('bad prepare',1,true))
print('SCHEMA_VALIDATION_AND_PREPARE_OK')
