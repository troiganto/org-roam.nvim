-------------------------------------------------------------------------------
-- SELECT-NODE.LUA
--
-- Opens a dialog to select a node, returning its id.
-------------------------------------------------------------------------------

---@alias org-roam.ui.NodeSelectItem {id:org-roam.core.database.Id, label:string, value:any, annotation?:string}

---@class (exact) org-roam.ui.SelectNodeOpts
---@field allow_select_missing? boolean
---@field auto_select? boolean
---@field exclude? string[]
---@field include? string[]
---@field init_input? string
---@field node_to_items? fun(node:org-roam.core.file.Node):org-roam.config.ui.SelectNodeItems
---@field annotation? fun(node:org-roam.core.file.Node):string

---@param roam OrgRoam
---@param opts org-roam.ui.SelectNodeOpts
---@return org-roam.core.ui.Select
local function roam_select_node(roam, opts)
    local node_to_items = opts.node_to_items or roam.config.ui.select.node_to_items
    local annotation_func = opts.annotation or roam.config.ui.select.annotation

    -- TODO: Make this more optimal. Probably involves supporting
    --       an async function to return items instead of an
    --       item list so we can query the database by name
    --       and by aliases to get candidate ids.
    ---@type org-roam.ui.NodeSelectItem[]
    local items = {}
    for _, id in ipairs(opts.include or roam.database:ids()) do
        local skip = false

        -- If we were given an exclusion list, check if the id is in that list
        -- and if so we will skip including this node in our dialog
        if opts.exclude and vim.tbl_contains(opts.exclude, id) then
            skip = true
        end

        if not skip then
            local node = roam.database:get_sync(id)
            if node then
                local node_items = node_to_items(node)
                local annotation = annotation_func and annotation_func(node)
                for _, item in ipairs(node_items) do
                    if type(item) == "string" then
                        table.insert(items, {
                            id = id,
                            label = item,
                            value = item,
                            annotation = annotation,
                        })
                    elseif type(item) == "table" then
                        table.insert(items, {
                            id = id,
                            label = item.label,
                            value = item.value,
                            annotation = annotation,
                        })
                    end
                end
            end
        end
    end

    -- Build our prompt, updating it to a left-hand side
    -- style if we have neovim 0.10+ which supports inlining
    local prompt = "(node {sel}/{cnt})"
    if vim.fn.has("nvim-0.10") == 1 then
        prompt = "{sel}/{cnt} node> "
    end

    ---@type org-roam.core.ui.select.Opts
    local select_opts = vim.tbl_extend("keep", {
        items = items,
        prompt = prompt,
        ---@param item org-roam.ui.NodeSelectItem
        format = function(item)
            return item.label
        end,
        annotate = function(item)
            return item.annotation
        end,
        cancel_on_no_init_matches = true,
    }, opts or {})

    return require("org-roam.core.ui.select"):new(select_opts)
end

---@param entry string
---@return org-roam.ui.NodeSelectItem?
local function parse_entry(entry)
    local id, value, label = entry:match("^([^\n]*)\n([^\n]*)\n(.*)$")
    return id and { id = id, value = value, label = label }
end

---@param roam OrgRoam
---@param opts org-roam.ui.SelectNodeOpts
---@return org-roam.core.ui.SelectFzf
local function fzf_select_node(roam, opts)
    local SelectFzf = require("org-roam.core.ui.select-fzf")
    local fzf_utils = require("fzf-lua.utils")
    local node_to_items = opts.node_to_items or roam.config.ui.select.node_to_items
    local annotation_func = opts.annotation or roam.config.ui.select.annotation

    ---@type string[] | fun(...)
    ---@param fzf_cb fun(item: any?, cb: fun()?): nil
    local contents = coroutine.wrap(function(fzf_cb)
        local co = coroutine.running()

        ---Yields from the current coroutine until the given promise completes.
        ---@param promise OrgPromise
        ---@return ...
        local function await(promise)
            local pack = require("org-roam.core.utils.table").pack
            local unpack = require("org-roam.core.utils.table").unpack
            ---@type boolean, string
            local ok, msg
            local result
            ---@diagnostic disable-next-line: undefined-field
            promise
                :next(function(...)
                    result = pack(...)
                    ok = true
                    coroutine.resume(co)
                end)
                :catch(function(...)
                    ok = false
                    msg = ...
                    coroutine.resume(co)
                end)
            coroutine.yield()
            assert(ok, msg)
            return unpack(result)
        end

        ---@param item org-roam.ui.NodeSelectItem
        local function add_item(item)
            fzf_cb(item, function()
                coroutine.resume(co)
            end)
            coroutine.yield()
        end
        local all_ids = opts.include and vim.iter(opts.include) or roam.database:iter_ids()
        for id in all_ids do --[[@cast id org-roam.core.database.Id]]
            local skip = false

            -- If we were given an exclusion list, check if the id is in that list
            -- and if so we will skip including this node in our dialog
            if opts.exclude and vim.tbl_contains(opts.exclude, id) then
                skip = true
            end

            if not skip then
                ---@type org-roam.core.file.Node?
                local node = await(roam.database:get(id))
                if node then
                    local node_items = node_to_items(node)
                    local annotation = annotation_func and annotation_func(node)
                    for _, item in ipairs(node_items) do
                        if type(item) == "string" then
                            add_item({
                                id = id,
                                label = item,
                                value = item,
                                annotation = annotation,
                            })
                        elseif type(item) == "table" then
                            add_item({
                                id = id,
                                label = item.label,
                                value = item.value,
                                annotation = annotation,
                            })
                        end
                    end
                end
            end
        end
        fzf_cb()
    end)

    return SelectFzf:new({
        items = contents,
        init_input = opts.init_input,
        allow_select_missing = opts.allow_select_missing,
        auto_select = opts.auto_select,
        prompt = "node> ",
        cancel_on_no_init_matches = true,
        formatter = {
            enrich = function(o)
                o.fzf_opts = vim.tbl_extend("keep", o.fzf_opts or {}, {
                    ["--delimiter"] = "\n",
                    ["--with-nth"] = "3..",
                    ["--read0"] = true,
                    ["--print0"] = true,
                })
            end,
            from = function(entry)
                local item = parse_entry(entry)
                local node = item and roam.database:get_sync(item.id)
                return node and ("%s:%d:%d"):format(node.file, node.range.start.row + 1, node.range.start.column + 1)
                    or ""
            end,
            ---@param item org-roam.ui.NodeSelectItem
            to = function(item)
                local id = item.id:gsub("\n", " ")
                local value = tostring(item.value):gsub("\n", " ")
                local label = item.label
                local annotation = item.annotation and fzf_utils.nbsp .. fzf_utils.ansi_codes.grey(item.annotation)
                    or ""
                local ret = ("%s\n%s\n%s%s"):format(id, value, label, annotation):gsub("%z", "\\0")
                return ret
            end,
        },
    })
end

---@class org-roam.ui.NodeSelect
---@field on_choice fun(self:org-roam.ui.NodeSelect, f: fun(selected: org-roam.ui.NodeSelectItem)): org-roam.ui.NodeSelect
---@field on_choice_missing fun(self:org-roam.ui.NodeSelect, f: fun(input: string)): org-roam.ui.NodeSelect
---@field on_cancel fun(self:org-roam.ui.NodeSelect, f: fun()): org-roam.ui.NodeSelect
---@field open fun(self:org-roam.ui.NodeSelect): nil

---@param roam OrgRoam
---@return org-roam.ui.SelectNodeApi
return function(roam)
    ---@class org-roam.ui.SelectNodeApi
    local M = {}

    ---Opens up a selection dialog populated with nodes (titles and aliases).
    ---@param opts? org-roam.ui.SelectNodeOpts
    ---@return org-roam.ui.NodeSelect
    function M.select_node_fzf(opts)
        opts = opts or {}

        ---@class org-roam.ui.FzfNodeSelect: org-roam.ui.NodeSelect
        local select = { __select = fzf_select_node(roam, opts) }

        ---@param f fun(selected:org-roam.ui.NodeSelectItem)
        ---@return org-roam.ui.NodeSelect
        function select:on_choice(f)
            self.__select:on_choice(function(selected)
                local item = parse_entry(selected)
                if item then
                    f(item)
                end
            end)
            return self
        end

        ---@param f fun(label:string)
        ---@return org-roam.ui.NodeSelect
        function select:on_choice_missing(f)
            self.__select:on_choice_missing(f)
            return self
        end

        ---@param f fun()
        ---@return org-roam.ui.NodeSelect
        function select:on_cancel(f)
            self.__select:on_cancel(f)
            return self
        end

        ---@return nil
        function select:open()
            self.__select:open()
        end

        return select
    end

    ---Opens up a selection dialog populated with nodes (titles and aliases).
    ---@param opts? {allow_select_missing?:boolean, auto_select?:boolean, exclude?:string[], include?:string[], init_input?:string}
    ---@return org-roam.ui.NodeSelect
    function M.select_node_builtin(opts)
        opts = opts or {}

        ---@class org-roam.ui.BuiltinNodeSelect: org-roam.ui.NodeSelect
        local select = { __select = roam_select_node(roam, opts) }

        ---@param f fun(selection:org-roam.ui.NodeSelectItem)
        ---@return org-roam.ui.NodeSelect
        function select:on_choice(f)
            self.__select:on_choice(f)
            return self
        end

        ---@param f fun(label:string)
        ---@return org-roam.ui.NodeSelect
        function select:on_choice_missing(f)
            self.__select:on_choice_missing(f)
            return self
        end

        ---@param f fun()
        ---@return org-roam.ui.NodeSelect
        function select:on_cancel(f)
            self.__select:on_cancel(f)
            return self
        end

        ---@return nil
        function select:open()
            self.__select:open()
        end

        return select
    end

    ---Opens up a selection dialog populated with nodes (titles and aliases).
    ---@param opts? org-roam.ui.SelectNodeOpts
    ---@return org-roam.ui.NodeSelect
    function M.select_node(opts)
        local backend = roam.config.ui.select.backend
        if backend == "fzf-lua" then
            return M.select_node_fzf(opts)
        elseif backend == "builtin" then
            return M.select_node_builtin(opts)
        else
            error("unknown select-node backend: " .. tostring(backend))
        end
    end

    return M
end
