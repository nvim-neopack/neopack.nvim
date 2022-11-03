local log = require("neopack.log")
local config = require("neopack.config")
local loader = require("neopack.loader")

local M = {}

M.packages = {}

local function parse_name(args)
  if args.as then
    return args.as
  elseif args.url then
    return args.url:gsub("%.git$", ""):match("/([%w-_.]+)$"), args.url
  else
    return args[1]:match("^[%w-]+/([%w-_.]+)$"), args[1]
  end
end

local function parse_package(opts)
  if type(opts) == "string" then
    opts = { opts }
  end

  opts = vim.tbl_deep_extend("force", config.options.packages.opts, opts)

  local name, repo = parse_name(opts)
  if not name then
    return log.error("Failed to parse", repo)
  elseif M.packages[name] then
    return
  end

  if type(opts.requires) == "string" then
    opts.requires = { opts.requires }
  end

  return vim.tbl_deep_extend("keep", opts, {
    name = name,
    status = "listed",
    repo = repo,
    url = opts.url or "https://github.com/" .. opts[1] .. ".git",
  })
end

M.use = function(opts)
  local pkg = parse_package(opts)
  if not pkg then
    return
  end

  M.packages[pkg.name] = pkg

  for handler_name, _ in pairs(pkg) do
    local handler = config.options.packages.handlers[handler_name]
    if handler then
      handler(pkg)
    end
  end

  pkg.basedir = config.options.path .. (pkg.opt and "opt/" or "start/")
  pkg.dir = config.options.path .. (pkg.opt and "opt/" or "start/") .. pkg.name
  pkg.exists = vim.fn.isdirectory(pkg.dir) ~= 0

  if pkg.requires then
    for _, requirement in ipairs(pkg.requires) do
      if type(requirement) == "string" then
        requirement = { requirement }
      end

      requirement.opt = pkg.opt
      M.use(requirement)
    end
  end

  if not pkg.opt then
    loader.load_package(pkg)
  end
end

return M
