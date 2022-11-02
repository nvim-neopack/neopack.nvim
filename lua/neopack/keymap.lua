local loader = require("neopack.loader")

local api = vim.api

---Shortcut for `nvim_replace_termcodes`.
---@param keys string
---@return string
local function termcodes(keys)
  return api.nvim_replace_termcodes(keys, true, true, true) --[[@as string]]
end

---Returns if two key sequence are equal or not.
---@param a string
---@param b string
---@return boolean
local function keymap_equals(a, b)
  return termcodes(a) == termcodes(b)
end

---Get map
---@param mode string
---@param lhs string
---@return table
local function get_map(mode, lhs)
  for _, map in ipairs(api.nvim_buf_get_keymap(0, mode)) do
    if keymap_equals(map.lhs, lhs) then
      return {
        lhs = map.lhs,
        rhs = map.rhs or "",
        expr = map.expr == 1,
        callback = map.callback,
        noremap = map.noremap == 1,
        script = map.script == 1,
        silent = map.silent == 1,
        nowait = map.nowait == 1,
        buffer = true,
      }
    end
  end

  for _, map in ipairs(api.nvim_get_keymap(mode)) do
    if keymap_equals(map.lhs, lhs) then
      return {
        lhs = map.lhs,
        rhs = map.rhs or "",
        expr = map.expr == 1,
        callback = map.callback,
        noremap = map.noremap == 1,
        script = map.script == 1,
        silent = map.silent == 1,
        nowait = map.nowait == 1,
        buffer = false,
      }
    end
  end

  return {
    lhs = lhs,
    rhs = lhs,
    expr = false,
    callback = nil,
    noremap = true,
    script = false,
    silent = true,
    nowait = false,
    buffer = false,
  }
end

---Returns the function constructed from the passed keymap object on call of
---which the original keymapping will be executed.
---@param map table keymap object
---@return function
local function get_original(map)
  return function()
    local keys, fmode
    if map.expr then
      if map.callback then
        keys = map.callback()
      else
        keys = api.nvim_eval(map.rhs)
      end
    elseif map.callback then
      map.callback()
      return
    else
      keys = map.rhs
    end
    keys = termcodes(keys)
    fmode = map.noremap and "in" or "im"
    api.nvim_feedkeys(keys, fmode, false)
  end
end

---@param mode string
---@param lhs string
---@param rhs string | function
---@param opts? table
local function amend(mode, lhs, rhs, opts)
  local map = get_map(mode, lhs)
  local original = get_original(map)
  opts = opts or {}
  opts.desc = table.concat({
    "[keymap-amend.nvim",
    (opts.desc and ": " .. opts.desc or ""),
    "] ",
    map.desc or "",
  })
  vim.keymap.set(mode, lhs, function()
    rhs(original)
  end, opts)
end

---Amend the existing keymap.
---@param mode string | string[]
---@param lhs string
---@param rhs string | function
---@param opts? table
local function modes_amend(mode, lhs, rhs, opts)
  if type(mode) == "table" then
    for _, m in ipairs(mode) do
      amend(m, lhs, rhs, opts)
    end
  else
    amend(mode, lhs, rhs, opts)
  end
end

local function parse_mode(mode)
  mode = mode or "n"

  if type(mode) == "string" and #mode > 1 then
    local splitted_value = {}
    mode:gsub(".", function(c)
      table.insert(splitted_value, c)
    end)
    mode = splitted_value
  end

  return mode
end

local keymap = {}

function keymap:new(opts)
  local this = {}

  opts = opts or {}

  self:prefix(opts.prefix or "", opts.label)
  self:mode(opts.mode or "n")
  self:ft(opts.ft)

  if opts.pkg then
    this.pkg = opts.pkg
    opts.pkg = nil
  end

  opts.ft = nil
  opts.prefix = nil
  opts.mode = nil
  opts.label = nil
  this.__opts = opts

  this.__mappings = {}

  setmetatable(this, self)
  self.__index = self

  return this
end

function keymap:set(lhs, rhs, opts)
  local prefix = self.__prefix or ""
  opts = vim.tbl_deep_extend("force", self.__opts, opts or {})

  local set_keymap = vim.schedule_wrap(function()
    vim.keymap.set(self.__mode, prefix .. lhs, rhs, opts)
    modes_amend(self.__mode, prefix .. lhs, function(original)
      loader.load_package(self.pkg)
      original()
    end)
  end, opts)

  if type(self.__ft) == "string" then
    vim.api.nvim_create_autocmd("FileType", {
      pattern = self.__ft,
      group = vim.api.nvim_create_augroup(self.__ft .. "_keymap", { clear = false }),
      callback = function()
        opts.buffer = 0
        set_keymap()
      end,
    })
  else
    set_keymap()
  end

  return self
end

function keymap:prefix(prefix, label)
  self.__prefix = prefix

  if prefix and label then
    local ok, wk = pcall(require, "which-key")
    if ok then
      wk.register({ name = label }, { prefix = prefix, mode = self.__mode })
    end
  end

  return self
end

function keymap:mode(mode)
  self.__mode = parse_mode(mode)
  return self
end

function keymap:ft(filetype)
  if filetype == "all" then
    self.__ft = nil
  else
    self.__ft = filetype
  end
  return self
end

return keymap
