local loader = require("neopack.loader")
local keymap = require("neopack.keymap")

local M = {}

local function make_optional(pkg)
  if pkg.opt ~= false then
    pkg.opt = true
  end
end

local default_opts = {
  packages = {
    handlers = {
      event = function(pkg)
        make_optional(pkg)
        loader.load_by_event(pkg, pkg.event)
      end,
      ft = function(pkg)
        make_optional(pkg)
        loader.load_by_ft(pkg, pkg.ft)
      end,
      keymap = function(pkg)
        make_optional(pkg)
        pkg.keymap(keymap:new({ pkg = pkg }))
      end,
    },
    opts = {
      protocol = "https",
      host = "github",
    },
  },
  path = vim.fn.stdpath("data") .. "/site/pack/neopack/",
  verbose = true,
  log = {
    path = vim.fn.stdpath("log") .. "/neopack.log",
  },
}

M.options = {}

M.setup = function(opts)
  M.options = vim.tbl_deep_extend("force", default_opts, opts or {})
end

M.setup()

return M
