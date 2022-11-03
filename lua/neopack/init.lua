local config = require("neopack.config")
local package = require("neopack.package")
local log = require("neopack.log")
local git = require("neopack.git")

local M = {}

local uv = vim.loop

local log_path = config.options.log.path

local packages = package.packages

local messages = {
  install = { ok = "Installed", err = "Failed to install" },
  update = { ok = "Updated", err = "Failed to update", nop = "(up-to-date)" },
  remove = { ok = "Removed", err = "Failed to remove" },
  hook = { ok = "Ran hook for", err = "Failed to run hook for" },
}

-- This is done only once. Doing it for every process seems overkill
local env = {}

for var, val in pairs(uv.os_environ()) do
  table.insert(env, ("%s=%s"):format(var, val))
end

table.insert(env, "GIT_TERMINAL_PROMPT=0")

local function report(op, name, res, n, total)
  local count = n and (" [%d/%d]"):format(n, total) or ""
  local msg = string.format("%s %s %s", count, messages[op][res], name)

  if res == "err" then
    log.error(msg)
  else
    log.info(msg)
  end
end

local function new_counter()
  return coroutine.wrap(function(op, total)
    local c = { ok = 0, err = 0, nop = 0 }
    while c.ok + c.err + c.nop < total do
      local name, res, over_op = coroutine.yield(true)
      c[res] = c[res] + 1
      if res ~= "nop" or config.options.verbose then
        report(over_op or op, name, res, c.ok + c.nop, total)
      end
    end
    local summary = "%s complete. %d ok; %d errors;" .. (c.nop > 0 and " %d no-ops" or "")
    log.info(summary:format(op, c.ok, c.err, c.nop))
    vim.cmd("packloadall! | silent! helptags ALL")
    vim.cmd("doautocmd User neopackDone" .. op:gsub("^%l", string.upper))
    return true
  end)
end

local function call_proc(process, args, cwd, cb, print_stdout)
  local log_file = uv.fs_open(log_path, "a+", 0x1A4)
  local stderr = uv.new_pipe(false)
  stderr:open(log_file)
  local handle, pid
  handle, pid = uv.spawn(
    process,
    {
      args = args,
      cwd = cwd,
      stdio = { nil, print_stdout and stderr, stderr },
      env = env,
    },
    vim.schedule_wrap(function(code)
      uv.fs_close(log_file)
      stderr:close()
      handle:close()
      cb(code == 0)
    end)
  )
  if not handle then
    log.error("Failed to spawn", process, pid)
  end
end

local function run_hook(pkg, counter, sync)
  local t = type(pkg.run)
  if t == "function" then
    vim.cmd.packadd(pkg.name)
    local res = pcall(pkg.run) and "ok" or "err"
    log.info("Ran hook for", pkg.name)
    return counter and counter(pkg.name, res, sync)
  elseif t == "string" then
    local args = {}
    for word in pkg.run:gmatch("%S+") do
      table.insert(args, word)
    end
    call_proc(table.remove(args, 1), args, pkg.dir, function(ok)
      local res = ok and "ok" or "err"
      log.info("Ran hook for", pkg.name)
      return counter and counter(pkg.name, res, sync)
    end)
    return true
  end
end

local function clone(pkg, counter, sync)
  git.clone(pkg, {
    on_exit = function(code)
      if code == 0 then
        pkg.exists = true
        pkg.status = "installed"
        return pkg.run and run_hook(pkg, counter, sync) or counter(pkg.name, "ok", sync)
      else
        counter(pkg.name, "err", sync)
      end
    end,
  })
end

local function pull(pkg, counter, sync)
  local prev_hash = git.get_hash(pkg)

  git.pull(pkg, {
    on_exit = function(code)
      if code ~= 0 then
        counter(pkg.name, "err", sync)
        return
      end

      local cur_hash = git.get_hash(pkg)
      if cur_hash ~= prev_hash then
        log.info(pkg.name .. " updating...")
        pkg.status = "updated"
        return pkg.run and run_hook(pkg, counter, sync) or counter(pkg.name, "ok", sync)
      else
        counter(pkg.name, "nop", sync)
      end
    end,
  })
end

local function clone_or_pull(pkg, counter)
  if pkg.exists and not pkg.pin then
    pull(pkg, counter, "update")
  elseif not pkg.exists then
    clone(pkg, counter, "install")
  end
end

local function walk_dir(path, fn)
  local handle = uv.fs_scandir(path)
  while handle do
    local name, t = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if not fn(path .. "/" .. name, name, t) then
      return
    end
  end
  return true
end

local function check_rm()
  local to_remove = {}
  for _, packdir in pairs({ "start", "opt" }) do
    walk_dir(config.options.path .. packdir, function(dir, name)
      if name == "neopack-nvim" then
        return true
      end
      local pkg = packages[name]
      if not (pkg and pkg.dir == dir) then
        table.insert(to_remove, { name = name, dir = dir })
      end
      return true
    end)
  end
  return to_remove
end

local function rmdir(dir, name, t)
  if t == "directory" then
    return walk_dir(dir, rmdir) and uv.fs_rmdir(dir)
  else
    return uv.fs_unlink(dir)
  end
end

local function remove(pkg, counter)
  local ok = walk_dir(pkg.dir, rmdir) and uv.fs_rmdir(pkg.dir)
  counter(pkg.name, ok and "ok" or "err")

  if ok then
    packages[pkg.name] = { name = pkg.name, status = "removed" }
  end
end

local function exe_op(op, fn, pkgs)
  if #pkgs == 0 then
    log.info("Nothing to " .. op)
    vim.cmd("doautocmd User neopackDone" .. op:gsub("^%l", string.upper))
    return
  end
  local counter = new_counter()
  counter(op, #pkgs)
  for _, pkg in pairs(pkgs) do
    fn(pkg, counter)
  end
end

local function list()
  local installed = vim.tbl_filter(function(pkg)
    return pkg.exists
  end, packages)
  table.sort(installed, function(a, b)
    return a.name < b.name
  end)

  local removed = vim.tbl_filter(function(pkg)
    return pkg.status == "removed"
  end, packages)
  table.sort(removed, function(a, b)
    return a.name < b.name
  end)

  local sym_tbl = { installed = "+", updated = "*", removed = " " }
  for header, pkgs in pairs({
    ["Installed packages:"] = installed,
    ["Recently removed:"] = removed,
  }) do
    if #pkgs ~= 0 then
      print(header)
      for _, pkg in ipairs(pkgs) do
        print(" ", sym_tbl[pkg.status] or " ", pkg.name)
      end
    end
  end
end

M.install = function()
  exe_op(
    "install",
    clone,
    vim.tbl_filter(function(pkg)
      return not pkg.exists and pkg.status ~= "removed"
    end, packages)
  )
end
M.update = function()
  exe_op(
    "update",
    pull,
    vim.tbl_filter(function(pkg)
      return pkg.exists and not pkg.pin
    end, packages)
  )
end
M.clean = function()
  exe_op("remove", remove, check_rm())
end
M.sync = function()
  M.clean()
  exe_op(
    "sync",
    clone_or_pull,
    vim.tbl_filter(function(pkg)
      return pkg.status ~= "removed"
    end, packages)
  )
end
M._run_hook = function(name)
  return run_hook(packages[name])
end
M._get_hooks = function()
  return vim.tbl_keys(vim.tbl_map(function(pkg)
    return pkg.run
  end, packages))
end
M.list = list
M.log_open = function()
  vim.cmd("sp " .. log_path)
end
M.log_clean = function()
  return assert(uv.fs_unlink(log_path)) and log.info("log file deleted")
end
M.use = package.use

M.setup = config.setup

return M
