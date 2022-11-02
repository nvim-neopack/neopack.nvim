local config = require("neopack.config")
local package = require("neopack.package")

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
  vim.notify((" neopack:%s %s %s"):format(count, messages[op][res], name), res == "err" and vim.log.levels.ERROR)
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
    local summary = (" neopack: %s complete. %d ok; %d errors;" .. (c.nop > 0 and " %d no-ops" or ""))
    vim.notify(summary:format(op, c.ok, c.err, c.nop))
    vim.cmd("packloadall! | silent! helptags ALL")
    vim.cmd("doautocmd User neopackDone" .. op:gsub("^%l", string.upper))
    return true
  end)
end

local function call_proc(process, args, cwd, cb, print_stdout)
  local log = uv.fs_open(log_path, "a+", 0x1A4)
  local stderr = uv.new_pipe(false)
  stderr:open(log)
  local handle, pid
  handle, pid = uv.spawn(
    process,
    { args = args, cwd = cwd, stdio = { nil, print_stdout and stderr, stderr }, env = env },
    vim.schedule_wrap(function(code)
      uv.fs_close(log)
      stderr:close()
      handle:close()
      cb(code == 0)
    end)
  )
  if not handle then
    vim.notify(string.format(" neopack: Failed to spawn %s (%s)", process, pid))
  end
end

local function log(message)
  local log = uv.fs_open(log_path, "a+", 0x1A4)
  uv.fs_write(log, message .. "\n")
  uv.fs_close(log)
end

local function run_hook(pkg, counter, sync)
  local t = type(pkg.run)
  if t == "function" then
    vim.cmd("packadd " .. pkg.name)
    local res = pcall(pkg.run) and "ok" or "err"
    report("hook", pkg.name, res)
    return counter and counter(pkg.name, res, sync)
  elseif t == "string" then
    local args = {}
    for word in pkg.run:gmatch("%S+") do
      table.insert(args, word)
    end
    call_proc(table.remove(args, 1), args, pkg.dir, function(ok)
      local res = ok and "ok" or "err"
      report("hook", pkg.name, res)
      return counter and counter(pkg.name, res, sync)
    end)
    return true
  end
end

local function clone(pkg, counter, sync)
  local args = { "clone", pkg.url, "--depth=1", "--recurse-submodules", "--shallow-submodules" }
  if pkg.branch then
    vim.list_extend(args, { "-b", pkg.branch })
  end
  vim.list_extend(args, { pkg.dir })
  call_proc("git", args, nil, function(ok)
    if ok then
      pkg.exists = true
      pkg.status = "installed"
      return pkg.run and run_hook(pkg, counter, sync) or counter(pkg.name, "ok", sync)
    else
      counter(pkg.name, "err", sync)
    end
  end)
end

local function get_git_hash(dir)
  local first_line = function(path)
    local file = io.open(path)
    if file then
      local line = file:read()
      file:close()
      return line
    end
  end
  local head_ref = first_line(dir .. "/.git/HEAD")
  return head_ref and first_line(dir .. "/.git/" .. head_ref:gsub("ref: ", ""))
end

local function pull(pkg, counter, sync)
  local prev_hash = get_git_hash(pkg.dir)
  call_proc("git", { "pull", "--recurse-submodules", "--update-shallow" }, pkg.dir, function(ok)
    if not ok then
      counter(pkg.name, "err", sync)
    else
      local cur_hash = get_git_hash(pkg.dir)
      if cur_hash ~= prev_hash then
        log(pkg.name .. " updating...")
        call_proc(
          "git",
          { "log", "--pretty=format:* %s", prev_hash .. ".." .. cur_hash },
          pkg.dir,
          function(ok) end,
          true
        )
        pkg.status = "updated"
        return pkg.run and run_hook(pkg, counter, sync) or counter(pkg.name, "ok", sync)
      else
        counter(pkg.name, "nop", sync)
      end
    end
  end)
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

local function remove(p, counter)
  local ok = walk_dir(p.dir, rmdir) and uv.fs_rmdir(p.dir)
  counter(p.name, ok and "ok" or "err")

  if ok then
    packages[p.name] = { name = p.name, status = "removed" }
  end
end

local function exe_op(op, fn, pkgs)
  if #pkgs == 0 then
    vim.notify(" neopack: Nothing to " .. op)
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
  for header, pkgs in pairs({ ["Installed packages:"] = installed, ["Recently removed:"] = removed }) do
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
M.sync = function(self)
  self:clean()
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
  return assert(uv.fs_unlink(log_path)) and vim.notify(" neopack: log file deleted")
end
M.use = package.use

M.setup = config.setup

return M
