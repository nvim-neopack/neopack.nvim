local log = require("neopack.log")
local config = require("neopack.config")
local uv = vim.loop

local M = {}

local protocols = {
  https = {
    prefix = "https://",
    postfix = "/",
  },
  ssh = {
    prefix = "git@",
    postfix = ":",
  },
}

local hosts = {
  github = "github.com",
  gitlab = "gitlab.com",
  codeberg = "codeberg.org",
  sourcehut = "git.sr.ht",
}

M.make_repo_uri = function(pkg)
  local protocol = protocols[pkg.protocol]
  local host = hosts[pkg.host] or pkg.host

  return protocol.prefix
    .. host
    .. protocol.postfix
    .. (pkg.host == "sourcehut" and "~" or "")
    .. pkg.repo
    .. (pkg.host ~= "sourcehut" and ".git" or "")
end

M.spawn = function(git_args, opts)
  local handle = uv.spawn("git", git_args, vim.schedule_wrap(opts.on_exit))

  if not handle then
    log.error("Failed to spawn git")
  end
end

M.clone = function(pkg, opts)
  local uri = M.make_repo_uri(pkg)
  local args = { "clone" }

  if pkg.depth then
    args = vim.list_extend(args, { "--depth", tostring(pkg.depth), "--no-single-branch" })
  end

  table.insert(args, uri)

  M.spawn({
    args = args,
    cwd = pkg.basedir,
  }, opts)
end

M.fetch = function(pkg, opts)
  M.spawn({
    args = { "fetch", "--all" },
    cwd = pkg.dir,
  }, opts)
end

M.log_updates = function(pkg, opts)
  M.spawn({
    args = { "--no-pager", "log", "..@{u}" },
    cwd = pkg.dir,
  }, opts)
end

M.get_hash = function(pkg)
  local first_line = function(path)
    local file = io.open(path)
    if file then
      local line = file:read()
      file:close()
      return line
    end
  end

  local head_ref = first_line(pkg.dir .. "/.git/HEAD")
  return head_ref and first_line(pkg.dir .. "/.git/" .. head_ref:gsub("ref: ", ""))
end

M.pull = function(pkg, opts)
  M.spawn({
    args = { "pull", "--recurse-submodules", "--update-shallow" },
    cwd = pkg.dir,
  }, opts)
end

return M
