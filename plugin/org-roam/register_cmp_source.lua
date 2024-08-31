---@param cmp {register_source: fun(name: string, source: org-roam.api.completion.CmpSource): integer}
---@return nil
local function register_in(cmp)
    local Source = require "org-roam.api.completion.cmp"
    cmp.register_source("org-roam", Source:new(require "org-roam"))
end

local has_cmp, cmp = pcall(require, "cmp")

if has_cmp then
    register_in(cmp)
else
    vim.api.nvim_create_autocmd("User", {
        pattern = "CmpReady",
        once = true,
        callback = function()
            register_in(require "cmp")
        end,
    })
end
