local lang = require("laravel_tools.lang")

local M = {}

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
-- "auto": usa Sail se existir vendor/bin/sail + arquivo compose.
-- true: força Sail.
-- false: usa o PHP do host.
M.use_sail = "auto"
M.artisan = nil
M.timeout = 60000

-- Arquivo real dentro do projeto para o LSP reconhecer as classes.
M.dir = ".tinker"
M.file = "console.php"
M.template = { "<?php", "", "" }

M.width = 0.9
M.height = 0.8
M.ratio = 0.55
M.border = "rounded"

-- Exibe automaticamente o resultado da última variável atribuída.
M.dump_result = true

M.keys = {
  run = { "<C-s>" },
  close = "<C-q>",
  to_output = "<C-l>",
  to_editor = "<C-h>",
}

---------------------------------------------------------------------------
-- Estado
---------------------------------------------------------------------------
local ns = vim.api.nvim_create_namespace("laravel_tinker")
local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local state = {
  open = false,
  root = nil,
  code = nil,
  out = nil,
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

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function as_list(value)
  return type(value) == "table" and value or { value }
end

---------------------------------------------------------------------------
-- Destaque da saída
---------------------------------------------------------------------------
local function setup_output_highlights()
  local groups = {
    LaravelTinkerString = "String",
    LaravelTinkerNumber = "Number",
    LaravelTinkerBoolean = "Boolean",
    LaravelTinkerNull = "Constant",
    LaravelTinkerType = "Type",
  }

  for name, target in pairs(groups) do
    vim.api.nvim_set_hl(0, name, {
      default = true,
      link = target,
    })
  end
end

local function highlight_matches(buf, row, line, pattern, group)
  local start = 1

  while start <= #line do
    local first, last = line:find(pattern, start)

    if not first then
      break
    end

    vim.api.nvim_buf_add_highlight(buf, ns, group, row, first - 1, last)
    start = math.max(last + 1, first + 1)
  end
end

local function highlight_string_ranges(line)
  local ranges = {}
  local i = 1

  while i <= #line do
    local quote = line:sub(i, i)

    if quote == '"' or quote == "'" then
      local start = i
      i = i + 1

      while i <= #line do
        local char = line:sub(i, i)

        if char == "\\" then
          -- Ignora o caractere escapado.
          i = i + 2
        elseif char == quote then
          i = i + 1
          break
        else
          i = i + 1
        end
      end

      ranges[#ranges + 1] = {
        start - 1,
        math.min(i - 1, #line),
      }
    else
      i = i + 1
    end
  end

  return ranges
end

local function overlaps_string(first, last, ranges)
  for _, range in ipairs(ranges) do
    if first < range[2] and last > range[1] then
      return true
    end
  end

  return false
end

local function highlight_matches_outside_strings(buf, row, line, pattern, group, ranges)
  local start = 1

  while start <= #line do
    local first, last = line:find(pattern, start)

    if not first then
      break
    end

    if not overlaps_string(first - 1, last, ranges) then
      vim.api.nvim_buf_add_highlight(buf, ns, group, row, first - 1, last)
    end

    start = math.max(last + 1, first + 1)
  end
end

local function highlight_output(buf, lines, header_hl)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  -- Mantém o destaque do status da execução na primeira linha.
  if header_hl and lines[1] then
    vim.api.nvim_buf_add_highlight(buf, ns, header_hl, 0, 0, #lines[1])
  end

  -- A primeira linha é o status e a segunda é um separador vazio.
  for index = 3, #lines do
    local row = index - 1
    local line = lines[index]
    local strings = highlight_string_ranges(line)

    -- Destaca a string inteira antes dos outros padrões.
    for _, range in ipairs(strings) do
      vim.api.nvim_buf_add_highlight(buf, ns, "LaravelTinkerString", row, range[1], range[2])
    end

    -- Booleanos fora das strings.
    highlight_matches_outside_strings(buf, row, line, "%f[%a]true%f[^%w_]", "LaravelTinkerBoolean", strings)

    highlight_matches_outside_strings(buf, row, line, "%f[%a]false%f[^%w_]", "LaravelTinkerBoolean", strings)

    -- null fora das strings.
    highlight_matches_outside_strings(buf, row, line, "%f[%a]null%f[^%w_]", "LaravelTinkerNull", strings)

    -- Números fora das strings.
    highlight_matches_outside_strings(buf, row, line, "%-?%d+%.?%d*", "LaravelTinkerNumber", strings)

    -- Nomes de tipos e classes fora das strings.
    highlight_matches_outside_strings(buf, row, line, "%u[%w_]*", "LaravelTinkerType", strings)

    highlight_matches_outside_strings(buf, row, line, "%f[%a]array%f[^%w_]", "LaravelTinkerType", strings)

    highlight_matches_outside_strings(buf, row, line, "%f[%a]object%f[^%w_]", "LaravelTinkerType", strings)
  end
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

    for _, file in ipairs({
      "docker-compose.yml",
      "docker-compose.yaml",
      "compose.yml",
      "compose.yaml",
    }) do
      if vim.fn.filereadable(root .. "/" .. file) == 1 then
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
    vim.bo[buf].filetype = "php"
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

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "Execute o código com " .. as_list(M.keys.run)[1],
  })

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
    pcall(vim.api.nvim_win_set_config, state.win_out, {
      title = " " .. text .. " ",
      title_pos = "center",
    })
  end
end

local function set_output(lines, hl)
  local buf = get_out_buf()

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  highlight_output(buf, lines, hl)

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
-- Preparação do código
---------------------------------------------------------------------------
local function prepare(lines)
  local result = {}

  for i, line in ipairs(lines) do
    if i == 1 then
      line = line:gsub("^%s*<%?php%s*", "")
    end

    result[#result + 1] = line
  end

  return vim.trim(table.concat(result, "\n"))
end

local function visual_lines(buf)
  local a = vim.fn.getpos("v")[2]
  local b = vim.fn.getpos(".")[2]

  vim.cmd("normal! \27")

  if a > b then
    a, b = b, a
  end

  return vim.api.nvim_buf_get_lines(buf, a - 1, b, false)
end

---------------------------------------------------------------------------
-- Dump automático
---------------------------------------------------------------------------
local function has_explicit_output(code)
  -- Não adiciona um segundo dump quando o código já imprime o resultado.
  -- dd() continua responsável por imprimir e interromper a execução.
  return code:match("%f[%a]dump%s*%(")
    or code:match("%f[%a]dd%s*%(")
    or code:match("%f[%a]var_dump%s*%(")
    or code:match("%f[%a]print_r%s*%(")
    or code:match("%f[%a]echo%f[%A]")
    or code:match("%f[%a]print%f[%A]")
end

local function last_assigned_variable(code)
  local last_var = nil

  for line in (code .. "\n"):gmatch("(.-)\n") do
    -- Reconhece atribuições simples como:
    -- $users = User::all();
    -- $result = $query->get();
    --
    -- Ignora operadores == e => para evitar falsos positivos.
    for var, rhs in line:gmatch("(%$[%a_][%w_]*)%s*=%s*(.)") do
      if rhs ~= "=" and rhs ~= ">" then
        last_var = var
      end
    end
  end

  return last_var
end

local function dump_expression_if_simple(code)
  local lines = vim.split(code, "\n", { plain = true })

  -- Localiza a última linha não vazia.
  local index

  for i = #lines, 1, -1 do
    if vim.trim(lines[i]) ~= "" then
      index = i
      break
    end
  end

  if not index then
    return code
  end

  local line = vim.trim(lines[index])
  local expression = line:match("^(.-);%s*$")

  if not expression or expression == "" then
    return code
  end

  -- Não transforma declarações, comandos de controle ou continuações
  -- de expressões multilinha em chamadas dump inválidas.
  if
    expression:match("^%s*use%s")
    or expression:match("^%s*namespace%s")
    or expression:match("^%s*declare%s")
    or expression:match("^%s*return%f[%A]")
    or expression:match("^%s*throw%f[%A]")
    or expression:match("^%s*if%f[%A]")
    or expression:match("^%s*elseif%f[%A]")
    or expression:match("^%s*else%f[%A]")
    or expression:match("^%s*foreach%f[%A]")
    or expression:match("^%s*for%f[%A]")
    or expression:match("^%s*while%f[%A]")
    or expression:match("^%s*switch%f[%A]")
    or expression:match("^%s*try%f[%A]")
    or expression:match("^%s*catch%f[%A]")
    or expression:match("^%s*finally%f[%A]")
    or expression:match("^%s*function%f[%A]")
    or expression:match("^%s*class%f[%A]")
    or expression:match("^%s*interface%f[%A]")
    or expression:match("^%s*trait%f[%A]")
    or expression:match("^%s*enum%f[%A]")
    or expression:match("^%s*}")
    or expression:match("^%s*%-%>")
    or expression:match("^%s*//")
    or expression:match("^%s*#")
  then
    return code
  end

  -- Evita transformar atribuições em dump(expression) desnecessariamente.
  -- A atribuição será tratada pelo dump da variável.
  if expression:match("^%s*%$[%a_][%w_]*%s*=") then
    return code
  end

  -- Uma expressão simples como User::all(); vira dump(User::all());
  -- A execução original da expressão é substituída, não duplicada.
  lines[index] = ("dump(%s);"):format(expression)

  return table.concat(lines, "\n")
end

local function add_automatic_dump(code)
  if not M.dump_result or has_explicit_output(code) then
    return code
  end

  local variable = last_assigned_variable(code)

  if variable then
    return code .. "\n\ndump(" .. variable .. ");"
  end

  return dump_expression_if_simple(code)
end

---------------------------------------------------------------------------
-- Saída do processo
---------------------------------------------------------------------------
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

---------------------------------------------------------------------------
-- Execução
---------------------------------------------------------------------------
function M.run(selection)
  if not state.open or not state.code then
    return warn("abra o Tinker primeiro (:Tinker)")
  end

  local lines = selection and visual_lines(state.code) or vim.api.nvim_buf_get_lines(state.code, 0, -1, false)

  local code = prepare(lines)

  if code == "" then
    return set_output({ "(nada para executar)" }, "Comment")
  end

  -- Adiciona dump automático antes de enviar o código ao Tinker.
  code = add_automatic_dump(code)

  save()
  stop_run()

  state.run_id = state.run_id + 1
  local id = state.run_id

  local cmd = artisan_cmd(state.root)

  vim.list_extend(cmd, {
    "tinker",
    "--no-interaction",
    "--no-ansi",
    "--execute=" .. code,
  })

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

  local ok, handle = pcall(vim.system, cmd, {
    cwd = state.root,
    text = true,
    timeout = M.timeout,
  }, function(res)
    vim.schedule(function()
      if id ~= state.run_id then
        return
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

      local output = { header, "" }

      if #body == 0 then
        output[#output + 1] = "(sem saída)"
      else
        vim.list_extend(output, body)
      end

      set_output(output, success and "DiagnosticOk" or "DiagnosticError")

      set_out_title("Resultado")
    end)
  end)

  if not ok then
    stop_timer()

    set_output({
      "✘ não consegui iniciar o artisan",
      "",
      tostring(handle),
    }, "DiagnosticError")

    set_out_title("Resultado")
    return
  end

  state.job = handle
end

---------------------------------------------------------------------------
-- Layout / janelas
---------------------------------------------------------------------------
local function win_configs()
  local cols = vim.o.columns
  local rows = vim.o.lines - vim.o.cmdheight

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
  vim.keymap.set(modes, lhs, fn, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Tinker: " .. desc,
  })

  for _, mode in ipairs(type(modes) == "table" and modes or { modes }) do
    state.maps[#state.maps + 1] = { buf, mode, lhs }
  end
end

local function unmap()
  for _, mapping in ipairs(state.maps) do
    pcall(vim.keymap.del, mapping[2], mapping[3], {
      buffer = mapping[1],
    })
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

---------------------------------------------------------------------------
-- Abrir / fechar / resetar
---------------------------------------------------------------------------
function M.close()
  if not state.open then
    return
  end

  state.open = false

  vim.cmd("stopinsert")
  save()
  stop_run()
  unmap()

  for _, win in ipairs({ state.win_code, state.win_out }) do
    if valid_win(win) then
      pcall(vim.api.nvim_win_close, win, true)
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

  local group = vim.api.nvim_create_augroup("LaravelTinkerWin", {
    clear = true,
  })

  for _, win in ipairs({ state.win_code, state.win_out }) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = tostring(win),
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

      local code, output = win_configs()

      if valid_win(state.win_code) then
        vim.api.nvim_win_set_config(state.win_code, code)
      end

      if valid_win(state.win_out) then
        vim.api.nvim_win_set_config(state.win_out, output)
      end
    end,
  })

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

function M.reset()
  local buf = state.code

  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = get_code_buf(lang.ui.find_root())
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.template)
  save(buf)
end

function M.setup()
  setup_output_highlights()

  vim.api.nvim_create_user_command("Tinker", function(opts)
    if opts.args == "repl" then
      return require("laravel_tools.commands").tinker_repl()
    elseif opts.args == "reset" then
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
