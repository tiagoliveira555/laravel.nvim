local lang = require("laravel_tools.lang")

local M = {}

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
-- "auto": ./vendor/bin/sail artisan se existir vendor/bin/sail + compose | true: força Sail | false: php do host
M.use_sail = "auto"
M.artisan = nil -- sobrescreve o comando base, ex.: { "docker", "compose", "exec", "-T", "laravel.test", "php", "artisan" }
M.timeout = 60000 -- ms

-- onde o board é salvo. Relativo = dentro do projeto (o LSP enxerga as classes do projeto).
-- Absoluto = pasta global (uma subpasta por projeto).
M.dir = ".tinker"
M.file = "console.php"
M.template = { "<?php", "", "" }

M.width = 0.9 -- fração da tela
M.height = 0.8
M.ratio = 0.55 -- fração da largura ocupada pelo board (o resto é o resultado)
M.border = "rounded"

M.keys = {
  run = { "<C-s>" }, -- n/i: salva e roda tudo | visual: roda só a seleção
  close = "<C-q>",
  to_output = "<C-l>", -- board -> resultado
  to_editor = "<C-h>", -- resultado -> board
}

---------------------------------------------------------------------------
-- Estado
---------------------------------------------------------------------------
local ns = vim.api.nvim_create_namespace("laravel_tinker")
local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local state = {
  open = false,
  root = nil,
  code = nil, -- buffer do board (arquivo real, para o LSP funcionar)
  out = nil, -- buffer do resultado (scratch)
  win_code = nil,
  win_out = nil,
  run_id = 0,
  job = nil,
  timer = nil,
  maps = {},
}

local function warn(msg)
  vim.notify("[tinker] " .. msg, vim.log.levels.WARN)
end

local function valid_win(w)
  return w ~= nil and vim.api.nvim_win_is_valid(w)
end

local function as_list(x)
  return type(x) == "table" and x or { x }
end

---------------------------------------------------------------------------
-- Artisan
---------------------------------------------------------------------------
local function artisan_cmd(root)
  if M.artisan then
    return vim.deepcopy(M.artisan)
  end
  local use = M.use_sail
  if use == "auto" then
    local has_compose = false
    for _, f in ipairs({ "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml" }) do
      if vim.fn.filereadable(root .. "/" .. f) == 1 then
        has_compose = true
        break
      end
    end
    use = has_compose and vim.fn.executable(root .. "/vendor/bin/sail") == 1
  end
  if use then
    return { "./vendor/bin/sail", "artisan" }
  end
  return { "php", "artisan" }
end

---------------------------------------------------------------------------
-- Arquivo do board
---------------------------------------------------------------------------
local function scratch_path(root)
  local dir = M.dir
  local absolute = dir:sub(1, 1) == "/" or dir:sub(1, 1) == "~"
  if absolute then
    dir = vim.fn.expand(dir) .. "/" .. vim.fn.sha256(root):sub(1, 8)
  else
    dir = root .. "/" .. dir
  end
  return dir, dir .. "/" .. M.file
end

local function get_code_buf(root)
  local dir, path = scratch_path(root)
  if vim.fn.filereadable(path) == 0 then
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(M.template, path)
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  if vim.bo[buf].filetype ~= "php" then
    vim.bo[buf].filetype = "php" -- dispara FileType -> LSP/treesitter
  end
  return buf
end

local function save(buf)
  buf = buf or state.code
  if buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent! noautocmd write")
    end)
  end
end

local function get_out_buf()
  if state.out and vim.api.nvim_buf_is_valid(state.out) then
    return state.out
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "laravel-tinker"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Execute o código com " .. as_list(M.keys.run)[1] })
  vim.bo[buf].modifiable = false
  vim.b[buf].completion = false
  state.out = buf
  return buf
end

---------------------------------------------------------------------------
-- Resultado
---------------------------------------------------------------------------
local function set_out_title(text)
  if valid_win(state.win_out) then
    pcall(vim.api.nvim_win_set_config, state.win_out, { title = " " .. text .. " ", title_pos = "center" })
  end
end

local function set_output(lines, hl)
  local b = get_out_buf()
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
  if hl and lines[1] then
    vim.api.nvim_buf_set_extmark(b, ns, 0, 0, { end_col = #lines[1], hl_group = hl })
  end
  if valid_win(state.win_out) then
    pcall(vim.api.nvim_win_set_cursor, state.win_out, { 1, 0 })
  end
end

local function stop_timer()
  if state.timer then
    state.timer:stop()
    if not state.timer:is_closing() then
      state.timer:close()
    end
    state.timer = nil
  end
end

local function stop_run()
  stop_timer()
  if state.job then
    pcall(function()
      state.job:kill(15)
    end)
    state.job = nil
  end
end

---------------------------------------------------------------------------
-- Execução
---------------------------------------------------------------------------
-- tira o `<?php` inicial (o tinker já executa em contexto PHP)
local function prepare(lines)
  local out = {}
  for i, l in ipairs(lines) do
    if i == 1 then
      l = (l:gsub("^%s*<%?php%s*", ""))
    end
    out[#out + 1] = l
  end
  return vim.trim(table.concat(out, "\n"))
end

local function visual_lines(buf)
  local a, b = vim.fn.getpos("v")[2], vim.fn.getpos(".")[2]
  vim.cmd("normal! \27")
  if a > b then
    a, b = b, a
  end
  return vim.api.nvim_buf_get_lines(buf, a - 1, b, false)
end

local function clean_output(raw)
  raw = raw:gsub("\27%[[%d;]*[A-Za-z]", ""):gsub("\r", "")
  local lines = vim.split(raw, "\n", { plain = true })
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  while #lines > 0 and vim.trim(lines[1]) == "" do
    table.remove(lines, 1)
  end
  return lines
end

-- selection = true: usa a seleção visual (só chamar a partir do modo visual)
function M.run(selection)
  if not state.open or not state.code then
    return warn("abra o Tinker primeiro (:Tinker)")
  end

  local lines = selection and visual_lines(state.code) or vim.api.nvim_buf_get_lines(state.code, 0, -1, false)
  local code = prepare(lines)
  if code == "" then
    return set_output({ "(nada para executar)" }, "Comment")
  end

  save()
  stop_run()
  state.run_id = state.run_id + 1
  local id = state.run_id

  local cmd = artisan_cmd(state.root)
  vim.list_extend(cmd, { "tinker", "--no-interaction", "--no-ansi", "--execute=" .. code })

  local t0 = vim.uv.hrtime()
  set_output({ "Executando…" }, "Comment")

  local frame = 0
  state.timer = vim.uv.new_timer()
  state.timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      frame = frame + 1
      set_out_title(("%s %.1fs"):format(SPIN[frame % #SPIN + 1], (vim.uv.hrtime() - t0) / 1e9))
    end)
  )

  local ok, handle = pcall(vim.system, cmd, { cwd = state.root, text = true, timeout = M.timeout }, function(res)
    vim.schedule(function()
      if id ~= state.run_id then
        return -- uma execução mais nova assumiu
      end
      stop_timer()
      state.job = nil

      local secs = (vim.uv.hrtime() - t0) / 1e9
      local body = clean_output((res.stdout or "") .. "\n" .. (res.stderr or ""))
      local success = res.code == 0
      local header
      if res.code == 124 then
        header = ("✘ timeout (%ds)"):format(M.timeout / 1000)
      elseif success then
        header = ("✔ %.2fs"):format(secs)
      else
        header = ("✘ código %s · %.2fs"):format(res.code, secs)
      end

      local out = { header, "" }
      if #body == 0 then
        out[#out + 1] = "(sem saída)"
      else
        vim.list_extend(out, body)
      end
      set_output(out, success and "DiagnosticOk" or "DiagnosticError")
      set_out_title("Resultado")
    end)
  end)

  if not ok then
    stop_timer()
    set_output({ "✘ não consegui iniciar o artisan", "", tostring(handle) }, "DiagnosticError")
    set_out_title("Resultado")
    return
  end
  state.job = handle
end

---------------------------------------------------------------------------
-- Layout / janelas
---------------------------------------------------------------------------
local function win_configs()
  local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local w = math.min(math.max(60, math.floor(cols * M.width)), cols - 2)
  local h = math.min(math.max(12, math.floor(rows * M.height)), rows - 2)
  local row = math.max(0, math.floor((rows - h) / 2) - 1)
  local col = math.max(0, math.floor((cols - w) / 2))
  local left = math.floor(w * M.ratio)

  local run_key = as_list(M.keys.run)[1]
  local code_cfg = {
    relative = "editor",
    row = row,
    col = col,
    width = math.max(10, left - 2),
    height = h - 2,
    style = "minimal",
    border = M.border,
    title = (" Tinker · %s "):format(vim.fs.basename(state.root or "")),
    title_pos = "center",
    footer = (" %s executar · visual: seleção · %s fechar "):format(run_key, M.keys.close),
    footer_pos = "center",
  }
  local out_cfg = {
    relative = "editor",
    row = row,
    col = col + left,
    width = math.max(10, w - left - 2),
    height = h - 2,
    style = "minimal",
    border = M.border,
    title = " Resultado ",
    title_pos = "center",
    footer = (" %s volta ao board "):format(M.keys.to_editor),
    footer_pos = "center",
  }
  return code_cfg, out_cfg
end

local function map(buf, modes, lhs, fn, desc)
  vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Tinker: " .. desc })
  for _, m in ipairs(type(modes) == "table" and modes or { modes }) do
    state.maps[#state.maps + 1] = { buf, m, lhs }
  end
end

local function unmap()
  for _, m in ipairs(state.maps) do
    pcall(vim.keymap.del, m[2], m[3], { buffer = m[1] })
  end
  state.maps = {}
end

local function focus(win)
  if valid_win(win) then
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(win)
  end
end

local function bind()
  for _, lhs in ipairs(as_list(M.keys.run)) do
    map(state.code, { "n", "i" }, lhs, function()
      M.run(false)
    end, "executar")
    map(state.code, "x", lhs, function()
      M.run(true)
    end, "executar seleção")
    map(state.out, "n", lhs, function()
      M.run(false)
    end, "executar")
  end
  map(state.code, { "n", "i" }, M.keys.close, M.close, "fechar")
  map(state.out, "n", M.keys.close, M.close, "fechar")
  map(state.out, "n", "q", M.close, "fechar")
  map(state.code, { "n", "i" }, M.keys.to_output, function()
    focus(state.win_out)
  end, "ir ao resultado")
  map(state.out, "n", M.keys.to_editor, function()
    focus(state.win_code)
  end, "ir ao board")
end

function M.close()
  if not state.open then
    return
  end
  state.open = false
  vim.cmd("stopinsert")
  save()
  stop_run()
  unmap()
  for _, w in ipairs({ state.win_code, state.win_out }) do
    if valid_win(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  state.win_code, state.win_out = nil, nil
  pcall(vim.api.nvim_del_augroup_by_name, "LaravelTinkerWin")
end

function M.open()
  if state.open and valid_win(state.win_code) then
    return focus(state.win_code)
  end

  local root = lang.ui.find_root()
  if vim.fn.filereadable(root .. "/artisan") == 0 then
    return warn("artisan não encontrado em " .. root)
  end

  state.root = root
  state.code = get_code_buf(root)
  state.out = get_out_buf()
  state.open = true

  local code_cfg, out_cfg = win_configs()
  state.win_out = vim.api.nvim_open_win(state.out, false, out_cfg)
  state.win_code = vim.api.nvim_open_win(state.code, true, code_cfg)

  vim.wo[state.win_code].number = true
  vim.wo[state.win_code].signcolumn = "yes"
  vim.wo[state.win_code].wrap = false
  vim.wo[state.win_out].wrap = true
  vim.wo[state.win_out].linebreak = true

  bind()

  local group = vim.api.nvim_create_augroup("LaravelTinkerWin", { clear = true })
  for _, w in ipairs({ state.win_code, state.win_out }) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = tostring(w),
      once = true,
      callback = function()
        vim.schedule(M.close)
      end,
    })
  end
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if not state.open then
        return
      end
      local a, b = win_configs()
      if valid_win(state.win_code) then
        vim.api.nvim_win_set_config(state.win_code, a)
      end
      if valid_win(state.win_out) then
        vim.api.nvim_win_set_config(state.win_out, b)
      end
    end,
  })

  -- cursor no fim; board vazio já entra em insert
  local last = vim.api.nvim_buf_line_count(state.code)
  local text = vim.api.nvim_buf_get_lines(state.code, last - 1, last, false)[1] or ""
  pcall(vim.api.nvim_win_set_cursor, state.win_code, { last, #text })
  if prepare(vim.api.nvim_buf_get_lines(state.code, 0, -1, false)) == "" then
    vim.cmd("startinsert!")
  end
end

function M.toggle()
  if state.open then
    M.close()
  else
    M.open()
  end
end

-- volta o board ao template
function M.reset()
  local buf = state.code
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = get_code_buf(lang.ui.find_root())
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.template)
  save(buf)
end

function M.setup()
  vim.api.nvim_create_user_command("Tinker", function(o)
    if o.args == "repl" then
      return require("laravel_tools.commands").tinker_repl()
    elseif o.args == "reset" then
      return M.reset()
    end
    M.toggle()
  end, {
    nargs = "?",
    complete = function()
      return { "repl", "reset" }
    end,
    desc = "Tinker board (repl = terminal, reset = limpa o board)",
  })
end

return M
