-------------------------------------------------------------------------------
-- SELECT-NODE.LUA
--
-- Opens a dialog to select a node, returning its id.
-------------------------------------------------------------------------------

local Select = require("org-roam.core.ui.select")

---@class CollectItemsOpts
---@field include? string[]
---@field exclude? string[]

---@class SelectNodeItem
---@field id org-roam.core.database.Id
---@field label string

---@param db org-roam.core.Database
---@param opts CollectItemsOpts
---@return SelectNodeItem[]
local function collect_items(db, opts)
  ---@type SelectNodeItem[]
  local items = {}
  ---@type table<org-roam.core.database.Id, org-roam.core.file.Node>
  local nodes = db:get_many(opts.include or db:ids())
  for id, node in pairs(nodes) do
    -- If we were given an exclusion list, check if the id is in that list
    -- and if so we will skip including this node in our dialog
    local skip = opts.exclude and vim.tbl_contains(opts.exclude, id)

    if not skip then
      table.insert(items, { id = id, label = node.title })
      for _, alias in ipairs(node.aliases) do
        -- Avoid repeat of alias that is same as title
        if alias ~= node.title then
          table.insert(items, { id = id, label = alias })
        end
      end
    end
  end
  return items
end

---@class SelectNodeOpts
---@field include? string[]
---@field exclude? string[]
---@field init_input? string
---@field auto_select? boolean
---@field allow_select_missing? boolean

---@param roam OrgRoam
---@param opts SelectNodeOpts
---@return org-roam.core.ui.Select
local function roam_select_node(roam, opts)
  local items = collect_items(roam.database:internal_sync(), { include = opts.include, exclude = opts.exclude })

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
    ---@param item SelectNodeItem
    format = function(item)
      return item.label
    end,
    cancel_on_no_init_matches = true,
  }, opts or {})

  return Select:new(select_opts)
end

---@param roam OrgRoam
---@return org-roam.ui.SelectNodeApi
return function(roam)
  ---@class org-roam.ui.SelectNodeApi
  local M = {}

  ---Opens up a selection dialog populated with nodes (titles and aliases).
  ---@param opts? {allow_select_missing?:boolean, auto_select?:boolean, exclude?:string[], include?:string[], init_input?:string}
  ---@return org-roam.ui.NodeSelect
  function M.select_node(opts)
    opts = opts or {}

    ---@class org-roam.ui.NodeSelect
    local select = { __select = roam_select_node(roam, opts) }

    ---@param f fun(selection:{id:org-roam.core.database.Id, label:string})
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

    ---@return integer win
    function select:open()
      return self.__select:open()
    end

    return select
  end

  return M
end
