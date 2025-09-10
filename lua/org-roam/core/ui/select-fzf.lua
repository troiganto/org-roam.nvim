-------------------------------------------------------------------------------
-- SELECT-FZF.LUA
--
-- alternative to `org-roam.core.ui.select` using fzf-lua.
-- See https://github.com/ibhagwan/fzf-lua/ for more information.
-------------------------------------------------------------------------------

local fzf = require("fzf-lua")
local fzf_config = require("fzf-lua.config")
local log = require("org-roam.core.log")

---@alias org-roam.core.ui.select-fzf.ItemsCallback fun(fzf_cb:fun(item:string?, cb:fun()?):nil)

---@class org-roam.core.ui.select-fzf.Formatter
---@field enrich fun(opts:fzf-lua.Config) #modify FZF options as the formatter requires
---@field from fun(entry:string, opts:fzf-lua.Config):string #turn an FZF entry into a string like `"file:col:row"`
---@field to fun(item:any, opts:fzf-lua.Config):string #turn an item of `contents` into an FZF entry

---@class org-roam.core.ui.SelectFzf
---@field private __contents any[]|fun(fzf_cb:fun(item:any?, cb:fun()?):nil)
---@field private __allow_select_missing boolean
---@field private __cancel_on_no_init_matches boolean
---@field private __auto_select boolean
---@field private __prompt string
---@field private __init_input string
---@field private __on_choice? fun(selected: string)
---@field private __on_choice_missing? fun(input: string)
---@field private __on_cancel? fun()
---@field private __formatter? org-roam.core.ui.select-fzf.Formatter
---@field private __get_preview_loc? fun(selected:string):fzf-lua.buffer_or_file.Entry
local M = {}
M.__index = M

---@class org-roam.core.ui.select-fzf.Opts
---@field items any[] | fun(fzf_cb:fun(item:any?, cb:fun()?):nil)
---@field prompt? string
---@field init_input? string
---@field auto_select? boolean
---@field allow_select_missing? boolean
---@field cancel_on_no_init_matches? boolean
---@field formatter? org-roam.core.ui.select-fzf.Formatter
---@field get_preview_loc? fun(selected:string):fzf-lua.buffer_or_file.Entry

---Creates a new org-roam select dialog.
---@param opts? org-roam.core.ui.select-fzf.Opts
---@return org-roam.core.ui.SelectFzf
function M:new(opts)
    opts = opts or {}
    local instance = setmetatable({}, M)
    instance.__contents = opts.items or {}
    instance.__allow_select_missing = opts.allow_select_missing or false
    instance.__auto_select = opts.auto_select or false
    instance.__cancel_on_no_init_matches = opts.cancel_on_no_init_matches or false
    instance.__prompt = opts.prompt or "> "
    instance.__init_input = opts.init_input or ""
    instance.__get_preview_loc = opts.get_preview_loc
    instance.__formatter = opts.formatter
    return instance
end

---Register callback when the selection dialog is canceled.
---@param f fun()
---@return org-roam.core.ui.SelectFzf
function M:on_cancel(f)
    self.__on_cancel = f
    return self
end

---Register callback when a selection is made.
---This is not triggered if the selection is canceled.
---@param f fun(selected: string)
---@return org-roam.core.ui.SelectFzf
function M:on_choice(f)
    self.__on_choice = f
    return self
end

---Register callback when a selection is made for a non-existent item.
---This will only be triggered when selection of missing items is enabled.
---This is not triggered if the selection is canceled.
---@param f fun(input: string)
---@return org-roam.core.ui.SelectFzf
function M:on_choice_missing(f)
    self.__on_choice_missing = f
    return self
end

---@param formatter org-roam.core.ui.select-fzf.Formatter
---@param contents any[]|org-roam.core.ui.select-fzf.ItemsCallback
---@param opts fzf-lua.Config
---@return string[]|org-roam.core.ui.select-fzf.ItemsCallback
local function format_contents(formatter, contents, opts)
    formatter.enrich(opts)
    if type(contents) == "table" then
        return vim.tbl_map(function(x)
            formatter.to(x, opts)
        end, contents)
    else
        ---@param fzf_cb fun(item:string?, cb:fun()?):nil
        return function(fzf_cb)
            ---@param item string?
            ---param cb: fun()?
            ---@return nil
            local function new_fzf_cb(item, cb)
                fzf_cb(item and formatter.to(item, opts), cb)
            end

            contents(new_fzf_cb)
        end
    end
end

---Opens the selection dialog.
---@return nil
function M:open()
    ---@param selected string[]
    ---@param opts fzf-lua.Config
    ---@return nil
    local function accept(selected, opts)
        if #selected ~= 0 and self.__on_choice then
            self.__on_choice(selected[1])
        elseif #selected == 0 and self.__allow_select_missing and self.__on_choice_missing then
            self.__on_choice_missing(opts.query)
        end
    end

    ---@return nil
    local function cancel()
        if self.__on_cancel then
            self.__on_cancel()
        end
    end

    ---@type table?
    local opts = {
        _fmt = self.__formatter,
        fzf_opts = {
            ["--select-1"] = self.__auto_select,
            ["--exit-0"] = self.__cancel_on_no_init_matches,
        },
        prompt = self.__prompt,
        query = self.__init_input,
        actions = {
            ["enter"] = { fn = accept, desc = "goto-node" },
            ["esc"] = { fn = cancel, desc = "abort" },
            ["ctrl-c"] = { fn = cancel, desc = "abort" },
            ["ctrl-q"] = { fn = cancel, desc = "abort" },
        },
        fn_selected = function(selected, opts)
            -- Catch abort via `--exit-0` flag; this would be swallowed by regular `act()`.
            if not selected or #selected == 0 then
                if self.__auto_select and opts.query == self.__init_input and self.__init_input ~= "" then
                    accept({}, opts)
                else
                    cancel()
                end
            end
            fzf.actions.act(selected, opts)
        end,
    }
    opts = fzf_config.normalize_opts(opts or {}, "roam_nodes")
    if not opts then
        return
    end

    local contents = self.__contents
    if opts._fmt then
        contents = format_contents(opts._fmt, contents, opts)
    end

    ---@type thread?, string?, fzf-lua.Config?
    local _, cmd, opts_final = fzf.fzf_exec(contents, opts)
    log.fmt_debug("fzf command: %s", cmd)
    log.fmt_debug("fzf options: %s", vim.inspect(opts_final))
end

function M.register_with_fzf()
    ---@param opts? {origin?:string, title?:string, templates?:table<string,OrgCaptureTemplateOpts>}
    fzf.register_extension("roam_nodes", function()
        require("org-roam").api.find_node()
    end, {
        fzf_opts = {
            ["--no-multi"] = true,
            ["--read0"] = true,
            ["--print0"] = true,
        },
        previewer = "builtin",
        winopts = {
            title = "org-roam-select",
            preview = { winopts = { conceallevel = 2 } },
        },
    })
end

return M
