local M = {}

---Wrap maxa_ai log  with prefix that respects enable_logging
---@param enable_logging boolean
function M.setup_logging(enable_logging)
    local maxa_ai_log = require("maxa.utils.log")
    M.log = setmetatable({}, {
        __index = function(_, method)
            return function(_, msg, ...)
                if enable_logging then
                    maxa_ai_log[method](maxa_ai_log, "[History] " .. msg, ...)
                end
            end
        end,
    })
end

return setmetatable(M, {
    __index = function(_, key)
        if key == "setup_logging" then
            return M.setup_logging
        end
        return M.log[key]
    end,
})
