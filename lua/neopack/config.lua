local loader = require("neopack.loader")
local keymap = require("neopack.keymap")

local M = {}

local default_opts = {
  packages = {
    handlers = {
      event = function(pkg)
        loader.load_by_event(pkg, pkg.event)
      end,
      ft = function(pkg)
        loader.load_by_ft(pkg, pkg.ft)
      end,
      keymap = function(pkg)
        pkg.keymap(keymap:new({ pkg = pkg }))
      end,
    },
    opts = {
      opt = true,
    },
  },
  path = vim.fn.stdpath("data") .. "/site/pack/neopacks/",
  verbose = false,
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
