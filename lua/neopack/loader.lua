local M = {}

M.load_package = function(pkg)
  if not pkg.exists or pkg.loaded then
    return
  end

  if pkg.setup then
    pkg.setup(pkg)
  end

  vim.cmd.packadd(pkg.name)

  if pkg.config then
    pkg.config(pkg)
  end
end

M.load_by_event = function(pkg, event, opts)
  opts = opts or {}
  local callback = opts.callback

  opts = vim.tbl_deep_extend("force", opts, {
    once = true,
    callback = vim.schedule_wrap(function()
      M.load_package(pkg)

      if callback then
        callback()
      end
    end),
  })

  return vim.api.nvim_create_autocmd(event, opts)
end

M.load_by_ft = function(pkg, ft)
  return M.load_by_event(pkg, "FileType", { pattern = ft })
end

return M
