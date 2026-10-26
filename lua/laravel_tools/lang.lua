local M = {}

-- mude para true para ver avisos/erros (ou: :lua require("laravel_tools.lang").debug = true)
M.debug = false

-- true: usa a janela de input própria (Esc cancela, autocomplete de chaves)
-- false: usa vim.ui.input (snacks/dressing), sem autocomplete
M.custom_input = true

-- true: depois de criar uma tradução nova (cursor sobre __('chave')), abre o arquivo de tradução
M.open_after_create = true

-- como mostrar vários usos de uma chave: "select" (lista) ou "quickfix"
M.usages_ui = "select"

-- mostra mensagens curtas na linha de comando (sem usos, sem chave sob o cursor...)
M.echo = true

-- true: em modo insert, dentro da chave de __('...'), mostra as chaves do mesmo
-- local do arquivo de tradução (e desliga outras fontes de completion naquele trecho).
-- Requer M.setup()
M.key_assist = true

local NS = vim.api.nvim_create_namespace("laravel_lang_input")
local MAXH = 10

---------------------------------------------------------------------------
-- Utilitários
---------------------------------------------------------------------------
local function notify(msg, level)
  if M.debug then
    vim.notify(msg, level or vim.log.levels.INFO)
  end
end

local function say(msg)
  if M.echo then
    vim.api.nvim_echo({ { msg, "WarningMsg" } }, false, {})
  end
end

local function esc(s)
  return (s:gsub("\\", "\\\\"):gsub("'", "\\'"))
end

local function unescape(q, raw)
  if q == "'" then
    return (raw:gsub("\\([\\'])", "%1"))
  end
  return (raw:gsub('\\(["\\])', "%1"))
end

local function norm_locale(s)
  return (s:lower():gsub("[-_]", ""))
end

-- remove espaços das pontas e colapsa espaços repetidos
local function squash(s)
  return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- texto curto, em uma linha, para listas
local function short(s, n)
  s = squash(s or "")
  if vim.fn.strchars(s) > n then
    s = vim.fn.strcharpart(s, 0, n) .. "…"
  end
  return s
end

local function read(path)
  if vim.fn.filereadable(path) == 1 then
    return table.concat(vim.fn.readfile(path), "\n")
  end
end

-- abre o arquivo e posiciona o cursor (line 1-based, col 0-based)
local function open_at(path, line, col)
  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  if line then
    pcall(vim.api.nvim_win_set_cursor, 0, { line, col or 0 })
    if not col then
      vim.cmd("normal! ^")
    end
    vim.cmd("normal! zz")
  end
end

local function is_blade_buf()
  return vim.api.nvim_buf_get_name(0):match("%.blade%.php$") ~= nil
end

---------------------------------------------------------------------------
-- Lista de sugestões (janela flutuante, caminho completo, sem truncar)
-- Itens: { word = "tenant/app.events.x", hint = "valor opcional" }
-- place(n, w) -> row, col, h   (posição em tela e altura do conteúdo)
---------------------------------------------------------------------------
local function new_list(place, minw)
  local L = { buf = nil, win = nil, items = {}, sel = 0, top = 1, longest = 0, minw = minw or 20 }

  function L:visible()
    return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
  end

  function L:close()
    if self.win and vim.api.nvim_win_is_valid(self.win) then
      pcall(vim.api.nvim_win_close, self.win, true)
    end
    self.win, self.buf = nil, nil
  end

  function L:current()
    return self.items[self.sel]
  end

  function L:render()
    local n = #self.items
    if n == 0 then
      return self:close()
    end

    local w = math.min(vim.o.columns - 4, math.max(self.minw, self.longest))
    local row, col, h = place(n, w)

    if self.sel > 0 then
      if self.sel < self.top then
        self.top = self.sel
      end
      if self.sel > self.top + h - 1 then
        self.top = self.sel - h + 1
      end
    end
    self.top = math.max(1, math.min(self.top, n - h + 1))

    local lines, hint_cols = {}, {}
    for i = self.top, self.top + h - 1 do
      local it = self.items[i]
      local line = (i == self.sel and "▸ " or "  ") .. it.word
      local hs
      if it.hint then
        hs = #line + 3
        line = line .. "   " .. it.hint
      end
      lines[#lines + 1] = line
      hint_cols[#hint_cols + 1] = hs or false
    end

    if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
      self.buf = vim.api.nvim_create_buf(false, true)
      vim.bo[self.buf].bufhidden = "wipe"
    end
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(self.buf, NS, 0, -1)
    for idx, hs in ipairs(hint_cols) do
      local absolute = self.top + idx - 1
      if hs and absolute ~= self.sel then
        vim.api.nvim_buf_set_extmark(self.buf, NS, idx - 1, hs, {
          end_col = #lines[idx],
          hl_group = "Comment",
        })
      end
    end
    if self.sel >= self.top and self.sel <= self.top + h - 1 then
      vim.api.nvim_buf_set_extmark(self.buf, NS, self.sel - self.top, 0, { line_hl_group = "PmenuSel" })
    end

    local wcfg = {
      relative = "editor",
      row = row,
      col = col,
      width = w,
      height = h,
      style = "minimal",
      border = "rounded",
      focusable = false,
      zindex = 60,
    }
    if self:visible() then
      vim.api.nvim_win_set_config(self.win, wcfg)
    else
      self.win = vim.api.nvim_open_win(self.buf, false, wcfg)
    end
    vim.wo[self.win].winhighlight = "NormalFloat:Pmenu,FloatBorder:FloatBorder"
  end

  function L:set(items)
    self.items = items
    self.sel, self.top = 0, 1
    local m = 0
    for _, it in ipairs(items) do
      local wd = vim.fn.strdisplaywidth(it.word)
      if it.hint then
        wd = wd + 3 + vim.fn.strdisplaywidth(it.hint)
      end
      m = math.max(m, wd)
    end
    self.longest = m + 2 -- prefixo "▸ "
    self:render()
  end

  function L:move(delta)
    local n = #self.items
    if n == 0 then
      return
    end
    if delta > 0 then
      self.sel = self.sel >= n and 1 or self.sel + 1
    else
      self.sel = self.sel <= 1 and n or self.sel - 1
    end
    self:render()
  end

  return L
end

---------------------------------------------------------------------------
-- Input próprio
-- opts = {
--   title = "...", footer = "...", default = "...",
--   complete = function(texto_ate_o_cursor) -> lista de { word, hint }   (opcional)
-- }
-- on_done(valor) com string (confirmou) ou nil (cancelou / perdeu o foco)
---------------------------------------------------------------------------
local function input(opts, on_done)
  if not M.custom_input then
    return vim.ui.input({
      prompt = (opts.title or "") .. (opts.footer and ("\n" .. opts.footer) or "") .. "\n",
      default = opts.default,
    }, on_done)
  end

  local default = opts.default or ""
  local title = " " .. (opts.title or "") .. " "
  local footer = opts.footer and (" " .. opts.footer .. " ") or nil

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.b[buf].completion = false -- impede blink.cmp / outros de interferirem
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { default })

  local want = math.max(
    60,
    vim.fn.strdisplaywidth(title) + 4,
    footer and (vim.fn.strdisplaywidth(footer) + 4) or 0,
    vim.fn.strdisplaywidth(default) + 10
  )
  local width = math.min(vim.o.columns - 4, want)

  local cfg = {
    relative = "editor",
    width = width,
    height = 1,
    row = math.max(1, math.floor(vim.o.lines / 3)),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  }
  if footer then
    cfg.footer = footer
    cfg.footer_pos = "center"
  end

  local win = vim.api.nvim_open_win(buf, true, cfg)
  vim.wo[win].wrap = false

  -- lista de sugestões logo abaixo do input
  local list = new_list(function(n, w)
    local room = vim.o.lines - (cfg.row + 3) - 3
    local h = math.max(1, math.min(n, MAXH, room))
    local col = math.max(0, math.min(cfg.col, vim.o.columns - w - 2))
    return cfg.row + 3, col, h
  end, width)

  -- fechamento --------------------------------------------------------
  local done = false
  local function finish(value, leave_insert)
    if done then
      return
    end
    done = true
    list:close()
    if leave_insert then
      vim.cmd("stopinsert")
    end
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
      on_done(value)
    end)
  end

  local function confirm()
    finish(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "", true)
  end
  local function cancel()
    finish(nil, true)
  end

  vim.keymap.set("n", "<CR>", confirm, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, nowait = true })
  for _, mode in ipairs({ "i", "n" }) do
    vim.keymap.set(mode, "<Esc>", cancel, { buffer = buf, nowait = true })
    vim.keymap.set(mode, "<C-c>", cancel, { buffer = buf, nowait = true })
  end

  -- autocomplete ------------------------------------------------------
  if opts.complete then
    local last

    local function refresh(force)
      if done or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
      local ok_c, pos = pcall(vim.api.nvim_win_get_cursor, win)
      local text = line:sub(1, ok_c and pos[2] or #line)
      if not force and text == last then
        return
      end
      last = text

      local ok, items = pcall(opts.complete, text)
      local filtered = {}
      if ok and items then
        for _, it in ipairs(items) do
          if it.word ~= text then
            filtered[#filtered + 1] = it
          end
        end
      end
      list:set(filtered)
    end

    local function accept()
      local item = list:current()
      if not item then
        return false
      end
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { item.word })
      pcall(vim.api.nvim_win_set_cursor, win, { 1, #item.word })
      refresh(true)
      return true
    end

    for _, lhs in ipairs({ "<Tab>", "<C-n>", "<Down>" }) do
      vim.keymap.set("i", lhs, function()
        list:move(1)
      end, { buffer = buf, nowait = true })
    end
    for _, lhs in ipairs({ "<S-Tab>", "<C-p>", "<Up>" }) do
      vim.keymap.set("i", lhs, function()
        list:move(-1)
      end, { buffer = buf, nowait = true })
    end
    vim.keymap.set("i", "<CR>", function()
      if not accept() then
        confirm()
      end
    end, { buffer = buf, nowait = true })

    vim.api.nvim_create_autocmd("TextChangedI", {
      buffer = buf,
      callback = function()
        refresh(false)
      end,
    })
    vim.defer_fn(function()
      refresh(true)
    end, 30)
  else
    vim.keymap.set("i", "<CR>", confirm, { buffer = buf, nowait = true })
  end

  -- perdeu o foco (clique fora, troca de janela...): cancela
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = buf,
    once = true,
    callback = function()
      finish(nil, false)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      list:close()
    end,
  })

  vim.cmd("startinsert!")
end

---------------------------------------------------------------------------
-- Projeto: raiz, pasta lang, locales
---------------------------------------------------------------------------
local function find_root()
  for _, markers in ipairs({ { "artisan" }, { "composer.json" }, { ".git" } }) do
    local r = vim.fs.root(0, markers)
    if r then
      return r
    end
  end
  return vim.fn.getcwd()
end

local function has_locales(dir)
  if vim.fn.isdirectory(dir) == 0 then
    return false
  end
  for _, name in ipairs(vim.fn.readdir(dir)) do
    if name ~= "vendor" and (vim.fn.isdirectory(dir .. "/" .. name) == 1 or name:match("%.json$")) then
      return true
    end
  end
  return false
end

local function lang_dir(root)
  for _, d in ipairs({ "lang", "resources/lang" }) do
    if has_locales(root .. "/" .. d) then
      return root .. "/" .. d
    end
  end
  return root .. "/lang"
end

local function list_locales(ld, want_json)
  local dirs, jsons = {}, {}
  if vim.fn.isdirectory(ld) == 1 then
    for _, name in ipairs(vim.fn.readdir(ld)) do
      if name ~= "vendor" then
        if vim.fn.isdirectory(ld .. "/" .. name) == 1 then
          table.insert(dirs, name)
        elseif name:match("%.json$") then
          table.insert(jsons, (name:gsub("%.json$", "")))
        end
      end
    end
  end
  if want_json then
    return #jsons > 0 and jsons or dirs
  end
  return #dirs > 0 and dirs or jsons
end

local function default_locale(root)
  local env = read(root .. "/.env")
  if env then
    local v = ("\n" .. env):match("\nAPP_LOCALE%s*=%s*[\"']?([%w_%-]+)")
    if v then
      return v
    end
  end
  local cfg = read(root .. "/config/app.php")
  if cfg then
    return cfg:match("['\"]locale['\"]%s*=>%s*env%(%s*['\"][%w_]+['\"]%s*,%s*['\"]([%w_%-]+)['\"]")
      or cfg:match("['\"]locale['\"]%s*=>%s*['\"]([%w_%-]+)['\"]")
  end
end

-- coloca o locale padrão (casando pt-BR / pt_BR / ptbr) na frente da lista
local function sort_locales(locales, default)
  if not default then
    return locales
  end
  local out, rest = {}, {}
  for _, l in ipairs(locales) do
    if norm_locale(l) == norm_locale(default) then
      table.insert(out, 1, l)
    else
      table.insert(rest, l)
    end
  end
  vim.list_extend(out, rest)
  return out
end

---------------------------------------------------------------------------
-- Parser de arquivos de tradução PHP (sem depender do PHP instalado)
-- Lê `return [ ... ];` / `return array( ... );` e devolve tabela Lua.
-- Valores que não são string/array (expressões, enums, concatenações)
-- são ignorados.
---------------------------------------------------------------------------
local DQ = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", ["$"] = "$" }

local function parse_php_lang(src)
  local pos, len = 1, #src

  local function skip()
    while pos <= len do
      local two = src:sub(pos, pos + 1)
      local c = two:sub(1, 1)
      if c:match("%s") then
        local _, e = src:find("^%s+", pos)
        pos = e + 1
      elseif two == "//" or (c == "#" and two ~= "#[") then
        local nl = src:find("\n", pos, true)
        pos = nl and nl + 1 or len + 1
      elseif two == "/*" then
        local _, e = src:find("*/", pos + 2, true)
        pos = e and e + 1 or len + 1
      else
        return
      end
    end
  end

  local function read_string()
    local q = src:sub(pos, pos)
    pos = pos + 1
    local stop_pat = q == "'" and "[\\']" or '[\\"]'
    local buf = {}
    while pos <= len do
      local s = src:find(stop_pat, pos)
      if not s then
        pos = len + 1
        break
      end
      if s > pos then
        buf[#buf + 1] = src:sub(pos, s - 1)
      end
      local c = src:sub(s, s)
      if c == q then
        pos = s + 1
        return table.concat(buf)
      end
      local n = src:sub(s + 1, s + 1)
      if q == "'" then
        if n == "'" or n == "\\" then
          buf[#buf + 1] = n
          pos = s + 2
        else
          buf[#buf + 1] = "\\"
          pos = s + 1
        end
      else
        local m = DQ[n]
        if m then
          buf[#buf + 1] = m
          pos = s + 2
        else
          buf[#buf + 1] = "\\"
          pos = s + 1
        end
      end
    end
    return table.concat(buf)
  end

  -- consome uma expressão desconhecida até `,` `]` `)` ou `=>` no nível 0
  local function skip_expr()
    local depth, start = 0, pos
    while pos <= len do
      local c = src:sub(pos, pos)
      local n = src:sub(pos + 1, pos + 1)
      if c == "'" or c == '"' then
        read_string()
      elseif c == "(" or c == "[" then
        depth = depth + 1
        pos = pos + 1
      elseif c == ")" or c == "]" then
        if depth == 0 then
          break
        end
        depth = depth - 1
        pos = pos + 1
      elseif c == "," and depth == 0 then
        break
      elseif c == "=" and n == ">" and depth == 0 then
        break
      elseif c == "/" and (n == "/" or n == "*") then
        skip()
      else
        pos = pos + 1
      end
    end
    return vim.trim(src:sub(start, pos - 1))
  end

  local parse_array

  -- retorna valor (string | tabela | nil) e, quando nil, o texto cru da expressão
  local function parse_value()
    skip()
    local c = src:sub(pos, pos)
    local val
    if c == "'" or c == '"' then
      val = read_string()
    elseif c == "[" then
      pos = pos + 1
      val = parse_array("]")
    else
      local s, e = src:find("^array%s*%(", pos)
      if not s then
        return nil, skip_expr()
      end
      pos = e + 1
      val = parse_array(")")
    end

    -- se vier algo além de um terminador (ex.: concatenação), descarta o valor
    skip()
    local n = src:sub(pos, pos)
    local is_arrow = n == "=" and src:sub(pos + 1, pos + 1) == ">"
    if pos <= len and n ~= "," and n ~= "]" and n ~= ")" and not is_arrow then
      return nil, skip_expr()
    end
    return val
  end

  parse_array = function(close)
    local t, idx = {}, 0
    while pos <= len do
      skip()
      local c = src:sub(pos, pos)
      if c == close then
        pos = pos + 1
        return t
      elseif c == "," then
        pos = pos + 1
      elseif c == "" then
        break
      else
        local before = pos
        local v, raw = parse_value()
        skip()
        if src:sub(pos, pos + 1) == "=>" then
          pos = pos + 2
          local k = v ~= nil and tostring(v) or raw
          local val = parse_value()
          if k ~= nil and val ~= nil then
            t[k] = val
          end
        else
          if v ~= nil then
            t[tostring(idx)] = v
          end
          idx = idx + 1
        end
        if pos == before then
          pos = pos + 1
        end -- evita loop infinito
      end
    end
    return t
  end

  local s, e = src:find("return%s*%[")
  local close = "]"
  if not s then
    s, e = src:find("return%s*array%s*%(")
    close = ")"
  end
  if not s then
    return nil
  end
  pos = e + 1
  return parse_array(close)
end

local function lang_table(path)
  local src = read(path)
  if not src then
    return nil
  end
  local ok, t = pcall(parse_php_lang, src)
  return ok and t or nil
end

local function flatten(t, prefix, cb)
  for k, v in pairs(t) do
    local key = prefix == "" and k or (prefix .. "." .. k)
    if type(v) == "table" then
      flatten(v, key, cb)
    else
      cb(key, v)
    end
  end
end

-- resolve `a.b.c` como o Laravel (chave plana primeiro, depois aninhada)
local function lookup_dotted(t, dotted)
  if t[dotted] ~= nil then
    return t[dotted]
  end
  local cur = t
  for seg in dotted:gmatch("[^%.]+") do
    if type(cur) ~= "table" or cur[seg] == nil then
      return nil
    end
    cur = cur[seg]
  end
  return cur
end

---------------------------------------------------------------------------
-- Existência / busca / listagens
---------------------------------------------------------------------------
-- retorna "exists", valor | "missing" | "unknown"
local function lookup_php(path, dotted)
  if vim.fn.filereadable(path) == 0 then
    return "missing"
  end
  local t = lang_table(path)
  if not t then
    return "unknown"
  end
  local v = lookup_dotted(t, dotted)
  if v == nil then
    return "missing"
  end
  return "exists", type(v) == "string" and v or "[array]"
end

local function lookup_json(path, key)
  local content = read(path)
  if not content then
    return "missing"
  end
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return "unknown"
  end
  if data[key] ~= nil then
    return "exists", tostring(data[key])
  end
  return "missing"
end

-- grupos (arquivos .php) de um locale: { "tenant/app", "enums", ... }
local function list_groups(ld, loc)
  local dir = ld .. "/" .. loc
  local groups = {}
  if vim.fn.isdirectory(dir) == 1 then
    for _, file in ipairs(vim.fn.globpath(dir, "**/*.php", false, true)) do
      groups[#groups + 1] = file:sub(#dir + 2, -5)
    end
  end
  table.sort(groups)
  return groups
end

-- chaves de um grupo: { {key="tenant/app.events.x", short="events.x", value="..."}, ... }
local function group_items(ld, loc, group)
  local t = lang_table(("%s/%s/%s.php"):format(ld, loc, group))
  if not t then
    return nil
  end
  local items = {}
  flatten(t, "", function(k, v)
    if type(v) == "string" then
      items[#items + 1] = { key = group .. "." .. k, short = k, value = v }
    end
  end)
  table.sort(items, function(a, b)
    return a.key < b.key
  end)
  return items
end

-- todas as chaves (todos os grupos .php + .json) de um locale
local function all_items(ld, loc)
  local items = {}
  for _, group in ipairs(list_groups(ld, loc)) do
    vim.list_extend(items, group_items(ld, loc, group) or {})
  end
  local json = read(ld .. "/" .. loc .. ".json")
  if json then
    local ok, data = pcall(vim.json.decode, json)
    if ok and type(data) == "table" then
      for k, v in pairs(data) do
        if type(v) == "string" then
          items[#items + 1] = { key = k, short = k, value = v }
        end
      end
    end
  end
  table.sort(items, function(a, b)
    return a.key < b.key
  end)
  return items
end

-- texto -> chaves existentes no locale `loc`
local function find_candidates(ld, loc, text)
  local want = squash(text)
  local res = {}
  for _, it in ipairs(all_items(ld, loc)) do
    if squash(it.value) == want then
      res[#res + 1] = it.key
    end
  end
  return res
end

-- autocomplete do caminho da chave (por nível: pasta/, arquivo., array.)
-- Retorna lista de { word = "...", hint = "valor (só nas chaves finais)" }
local function key_completer(ld, loc)
  local groups
  local cache = {}

  local function get_groups()
    groups = groups or list_groups(ld, loc)
    return groups
  end

  local function get_keys(group)
    if cache[group] then
      return cache[group]
    end
    local out = {}
    for _, it in ipairs(group_items(ld, loc, group) or {}) do
      out[#out + 1] = { short = it.short, value = it.value }
    end
    cache[group] = out
    return out
  end

  return function(text)
    local items, seen = {}, {}
    local function add(word, hint)
      if not seen[word] then
        seen[word] = true
        items[#items + 1] = { word = word, hint = hint }
      end
    end

    local dot = text:find(".", 1, true)
    if not dot then
      -- ainda digitando o grupo (pasta/arquivo)
      for _, g in ipairs(get_groups()) do
        if g:sub(1, #text) == text then
          local nxt = g:find("/", #text + 1, true)
          add(nxt and g:sub(1, nxt) or (g .. "."))
        end
      end
    else
      local group, sub = text:sub(1, dot - 1), text:sub(dot + 1)
      for _, k in ipairs(get_keys(group)) do
        if k.short:sub(1, #sub) == sub then
          local nxt = k.short:find(".", #sub + 1, true)
          if nxt then
            add(group .. "." .. k.short:sub(1, nxt))
          else
            add(group .. "." .. k.short, short(k.value, 60))
          end
        end
      end
    end

    table.sort(items, function(a, b)
      return a.word < b.word
    end)
    return items
  end
end

---------------------------------------------------------------------------
-- Detecção: chamadas de tradução (com props) e literais de string
---------------------------------------------------------------------------
local CALL_NAMES = { "trans_choice", "Lang::get", "@lang", "trans", "__" }

-- linhas seguintes (juntas) para chamadas que continuam em várias linhas
local function following_lines(row0)
  return table.concat(vim.api.nvim_buf_get_lines(0, row0 + 1, row0 + 16, false), " ")
end

-- índice do `)` que fecha o `(` em open_idx (nil se não fechar)
local function find_close(text, open_idx)
  local depth, i, n = 0, open_idx, #text
  while i <= n do
    local c = text:sub(i, i)
    if c == "'" or c == '"' then
      local j = i + 1
      while j <= n do
        local d = text:sub(j, j)
        if d == "\\" then
          j = j + 2
        elseif d == c then
          break
        else
          j = j + 1
        end
      end
      i = j
    elseif c == "(" or c == "[" or c == "{" then
      depth = depth + 1
    elseif c == ")" or c == "]" or c == "}" then
      depth = depth - 1
      if depth == 0 then
        return i
      end
    end
    i = i + 1
  end
end

-- nomes dos props: strings seguidas de `=>` no primeiro nível do array
local function parse_props(args)
  local props, seen = {}, {}
  local i, n, depth = 1, #args, 0
  while i <= n do
    local c = args:sub(i, i)
    if c == "'" or c == '"' then
      local j = i + 1
      while j <= n do
        local d = args:sub(j, j)
        if d == "\\" then
          j = j + 2
        elseif d == c then
          break
        else
          j = j + 1
        end
      end
      if depth == 1 and args:sub(j + 1):match("^%s*=>") then
        local k = args:sub(i + 1, j - 1)
        if k:match("^[%a_][%w_]*$") and not seen[k] then
          seen[k] = true
          props[#props + 1] = k
        end
      end
      i = j + 1
    else
      if c == "(" or c == "[" or c == "{" then
        depth = depth + 1
      elseif c == ")" or c == "]" or c == "}" then
        depth = depth - 1
      end
      i = i + 1
    end
  end
  return props
end

-- chamadas de tradução na linha. Índices 1-based:
-- { s = início da função, ks = aspa de abertura da chave, ke = aspa de fechamento, key, props }
-- (o conteúdo da chave vai de ks+1 até ke-1)
local function scan_calls(line, more)
  local calls = {}
  local full = line .. " " .. (more or "")
  for _, fn in ipairs(CALL_NAMES) do
    local init = 1
    while true do
      local s, e = line:find(vim.pesc(fn) .. "%(", init)
      if not s then
        break
      end
      init = e + 1
      local prev = s > 1 and line:sub(s - 1, s - 1) or ""
      if fn:sub(1, 1) == "@" or not prev:match("[%w_$>:]") then
        local ms, ke, _, key = line:find("^%s*(['\"])(.-)%1", e + 1)
        if ms then
          local qs = e + 1 + #line:match("^%s*", e + 1)
          local close = find_close(full, e)
          local args = close and full:sub(ke + 1, close - 1) or full:sub(ke + 1)
          calls[#calls + 1] = { s = s, ks = qs, ke = ke, key = key, props = parse_props(args) }
        end
      end
    end
  end
  return calls
end

-- chamada que se sobrepõe ao intervalo [c1, c2] (a mais específica)
local function call_at(line, more, c1, c2)
  c2 = c2 or c1
  local best
  for _, c in ipairs(scan_calls(line, more)) do
    if c1 <= c.ke and c2 >= c.s then
      if not best or (c.ke - c.s) < (best.ke - best.s) then
        best = c
      end
    end
  end
  return best
end

-- Contexto de modo insert: cursor dentro da chave de uma chamada (mesmo sem aspa de fechamento).
-- c0 = bytes antes do cursor (0-based). Retorna { qs, close, prefix }:
--   qs     = índice da aspa de abertura (= coluna 0-based do 1º caractere da chave)
--   close  = índice da aspa de fechamento (nil se ainda não digitada)
--   prefix = texto da chave até o cursor
local function key_context(line, c0)
  for _, fn in ipairs(CALL_NAMES) do
    local init = 1
    while true do
      local s, e = line:find(vim.pesc(fn) .. "%(%s*['\"]", init)
      if not s then
        break
      end
      init = e + 1
      local prev = s > 1 and line:sub(s - 1, s - 1) or ""
      if fn:sub(1, 1) == "@" or not prev:match("[%w_$>:]") then
        local q = line:sub(e, e)
        local close = line:find(q, e + 1, true)
        local last = (close or (#line + 1)) - 1
        if c0 >= e and c0 <= last then
          return { qs = e, close = close, prefix = line:sub(e + 1, c0) }
        end
      end
    end
  end
end

-- literal de string que contém a coluna: início, fim (aspas incluídas), aspa
local function string_span_at(line, col)
  local i, n = 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == "'" or c == '"' then
      local j = i + 1
      while j <= n do
        local d = line:sub(j, j)
        if d == "\\" then
          j = j + 2
        elseif d == c then
          break
        else
          j = j + 1
        end
      end
      if j > n then
        return
      end
      if col >= i and col <= j then
        return i, j, c
      end
      if i > col then
        return
      end
      i = j + 1
    else
      i = i + 1
    end
  end
end

-- classifica a string: "php" (código) ou "attr" (valor de atributo HTML em Blade)
local function string_ctx(line, col, is_blade)
  local i, j, q = string_span_at(line, col)
  if not i then
    return
  end
  if not is_blade then
    return i, j, q, "php"
  end

  local before = line:sub(1, i - 1)
  if before:match("[%w_:@%.%-]+=$") then
    return i, j, q, "attr"
  end
  if before:find("{{", 1, true) or before:find("{!!", 1, true) or before:find("@[%w_]+%s*%(") or before:find("<%?") then
    return i, j, q, "php"
  end
end

local function default_build(key)
  return ("__('%s')"):format(esc(key))
end

local function blade_echo_build(key)
  return ("{{ __('%s') }}"):format(esc(key))
end

-- Decide o trecho a substituir e como montar o resultado.
-- s, e: seleção (colunas 1-based); em modo normal, s == e == cursor e collapsed = true.
-- Retorna s, e, texto, build  (ou nil)
local function plan_replacement(line, is_blade, s, e, collapsed)
  local i, j, q, kind = string_ctx(line, s, is_blade)

  if i then
    local cs, ce = i + 1, j - 1 -- conteúdo da string
    if collapsed then
      s, e = cs, ce
    end
    s, e = math.max(s, cs), math.min(e, ce)
    if s > e then
      return
    end

    local text = unescape(q, line:sub(s, e))
    local full = (s == cs and e == ce)

    if kind == "attr" then
      -- componentes (<x-..>, <livewire:..>, <flux:..>): :attr="__('chave')"
      if full and q == '"' then
        local before = line:sub(1, i - 1)
        local name_s = before:find("[%w_:@%.%-]+=$")
        local tag = before:match(".*<([%w_:%-%.]+)[^<>]*$")
        local is_comp = tag and (tag:match("^x%-") or tag:match("^livewire:") or tag:match("^flux:"))
        if name_s and is_comp then
          local name = line:sub(name_s, i - 2)
          if not name:match("^[:@]") then
            return name_s,
              j,
              text,
              function(key)
                return (":%s=\"__('%s')\""):format(name, esc(key))
              end
          end
        end
      end
      return s, e, text, blade_echo_build
    end

    -- string PHP inteira
    if full then
      return i, j, text, default_build
    end

    -- trecho dentro da string: vira concatenação ('antes' . __('chave') . 'depois')
    local left, right = line:sub(cs, s - 1), line:sub(e + 1, ce)
    return i,
      j,
      text,
      function(key)
        local out = {}
        if left ~= "" then
          out[#out + 1] = q .. left .. q .. " . "
        end
        out[#out + 1] = default_build(key)
        if right ~= "" then
          out[#out + 1] = " . " .. q .. right .. q
        end
        return table.concat(out)
      end
  end

  -- fora de string: só faz sentido em Blade (texto solto), com seleção
  if collapsed or not is_blade then
    return
  end

  local seg = line:sub(s, e)
  local lead = seg:match("^%s*<[^<>]*>%s*()")
  local trail = seg:match("()%s*<[^<>]*>%s*$")
  if lead and trail and trail > lead then
    s, e = s + lead - 1, s + trail - 2
  end

  local text = line:sub(s, e)
  if text:match("^%s*$") then
    return
  end
  return s, e, text, blade_echo_build
end

---------------------------------------------------------------------------
-- Localização e escrita em arquivos de tradução
---------------------------------------------------------------------------
local function find_key(lines, s, e, indent, seg)
  local pat = "^" .. indent .. "['\"]" .. vim.pesc(seg) .. "['\"]%s*=>%s*(.*)$"
  for i = s, e do
    local rest = lines[i]:match(pat)
    if rest then
      if rest:match("^%[%s*$") or rest:match("^array%(%s*$") then
        for j = i + 1, e do
          if lines[j]:match("^" .. indent .. "[%])]") then
            return i, j, "array"
          end
        end
      end
      return i, i, "value"
    end
  end
end

-- linhas de abertura/fechamento do `return [ ... ];` e unidade de indentação
local function php_bounds(lines)
  local open, close
  for i, l in ipairs(lines) do
    if l:match("^return%s*%[") then
      open = i
      break
    end
  end
  for i = #lines, 1, -1 do
    if lines[i]:match("^%];?%s*$") then
      close = i
      break
    end
  end
  if not open or not close then
    return nil
  end

  local unit = "    "
  for i = open + 1, close - 1 do
    local ws = lines[i]:match("^(%s+)%S")
    if ws then
      unit = ws
      break
    end
  end
  return open, close, unit
end

-- linha (1-based) e coluna (0-based) da chave em um arquivo PHP de tradução
local function locate_php(path, segs, dotted)
  local lines = vim.fn.readfile(path)
  local function colof(l)
    return (l:find("['\"]") or 1) - 1
  end

  -- 1) chave plana: 'a.b.c' => ...
  local flat = "^%s*['\"]" .. vim.pesc(dotted) .. "['\"]%s*=>"
  for i, l in ipairs(lines) do
    if l:match(flat) then
      return i, colof(l)
    end
  end

  -- 2) caminho aninhado, respeitando a indentação de cada nível
  local open, close, unit = php_bounds(lines)
  if open then
    local s, e, indent = open + 1, close - 1, unit
    local found
    for n, seg in ipairs(segs) do
      local i, j, kind = find_key(lines, s, e, indent, seg)
      if not i then
        found = nil
        break
      end
      found = i
      if n < #segs then
        if kind ~= "array" then
          found = nil
          break
        end
        s, e, indent = i + 1, j - 1, indent .. unit
      end
    end
    if found then
      return found, colof(lines[found])
    end
  end

  -- 3) fallback solto: acha os segmentos em sequência, qualquer indentação
  local from, found = 1, nil
  for _, seg in ipairs(segs) do
    local pat = "^%s*['\"]" .. vim.pesc(seg) .. "['\"]%s*=>"
    local hit
    for i = from, #lines do
      if lines[i]:match(pat) then
        hit = i
        break
      end
    end
    if not hit then
      return nil
    end
    found, from = hit, hit + 1
  end
  if found then
    return found, colof(lines[found])
  end
end

-- linha e coluna da chave em um arquivo .json
local function locate_json(path, key)
  local lines = vim.fn.readfile(path)
  local enc = vim.json.encode(key)
  local alts = { enc, (enc:gsub("\\/", "/")) }
  for i, l in ipairs(lines) do
    for _, a in ipairs(alts) do
      local s = l:find(a, 1, true)
      if s and l:sub(1, s - 1):match("^%s*$") and l:sub(s + #a):match("^%s*:") then
        return i, s - 1
      end
    end
  end
end

-- insere `segs` (chave aninhada) no arquivo; retorna true, linha_inserida | false, erro
local function add_php(path, segs, value)
  local lines
  if vim.fn.filereadable(path) == 1 then
    lines = vim.fn.readfile(path)
  else
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    lines = { "<?php", "", "return [", "];" }
  end

  local open, close, unit = php_bounds(lines)
  if not open then
    return false, "formato inesperado (não achei 'return [' ou '];')"
  end

  local s, e, blockclose = open + 1, close - 1, close
  local indent = unit

  for n, seg in ipairs(segs) do
    local i, j, kind = find_key(lines, s, e, indent, seg)
    if i then
      if n == #segs then
        return false, "já existe"
      end
      if kind ~= "array" then
        return false, ("'%s' já existe como valor, não como array"):format(seg)
      end
      s, e, blockclose = i + 1, j - 1, j
      indent = indent .. unit
    else
      local new, ind = {}, indent
      for m = n, #segs - 1 do
        new[#new + 1] = ind .. "'" .. esc(segs[m]) .. "' => ["
        ind = ind .. unit
      end

      local left = ind .. "'" .. esc(segs[#segs]) .. "'"
      local pad = " "
      -- alinha a seta com o vizinho anterior (estilo Pint / align_double_arrow)
      local prev = lines[blockclose - 1] or ""
      if prev:match("^" .. indent .. "['\"][^'\"]*['\"]%s*=>") then
        local arrow_col = prev:find("=>", 1, true)
        pad = string.rep(" ", math.max(1, arrow_col - 1 - #left))
      end
      new[#new + 1] = left .. pad .. "=> '" .. esc(value) .. "',"

      for _ = #segs - 1, n, -1 do
        ind = ind:sub(1, -#unit - 1)
        new[#new + 1] = ind .. "],"
      end
      for k, l in ipairs(new) do
        table.insert(lines, blockclose + k - 1, l)
      end
      vim.fn.writefile(lines, path)
      return true, blockclose + (#segs - n) -- linha da chave inserida
    end
  end
end

local function add_json(path, key, value)
  local content = "{}"
  if vim.fn.filereadable(path) == 1 then
    content = table.concat(vim.fn.readfile(path), "\n")
  else
    vim.fn.mkdir(vim.fs.dirname(path), "p")
  end
  local entry = ("    %s: %s"):format(vim.json.encode(key), vim.json.encode(value)):gsub("\\/", "/")
  local body = content:gsub("%s*}%s*$", "")
  local new
  if body:match("{%s*$") then
    new = body .. "\n" .. entry .. "\n}\n"
  else
    new = body .. ",\n" .. entry .. "\n}\n"
  end
  vim.fn.writefile(vim.split(new, "\n", { plain = true }), path)
  return true
end

---------------------------------------------------------------------------
-- Fluxo 1: chave de tradução
--   existe em 1 arquivo      -> vai direto
--   existe em vários locales -> lista para escolher o arquivo
--   não existe               -> cria SOMENTE no locale padrão
---------------------------------------------------------------------------
local function key_info(key)
  local root = find_root()
  local ld = lang_dir(root)

  -- grupo pode ter subpastas: tenant/app.events.meeting_not_available
  local group, rest = key:match("^([%w_%-/]+)%.(.+)$")
  local is_json = (not group) or key:find("%s") ~= nil
  local segs = group and vim.split(rest, ".", { plain = true }) or nil

  local locales = sort_locales(list_locales(ld, is_json), default_locale(root))
  if #locales == 0 then
    notify(("Nenhum locale encontrado em %s (raiz: %s)"):format(ld, root), vim.log.levels.ERROR)
    return nil
  end

  return {
    key = key,
    root = root,
    ld = ld,
    group = group,
    rest = rest,
    segs = segs,
    is_json = is_json,
    locales = locales,
  }
end

local function path_for(info, loc)
  if info.is_json then
    return ("%s/%s.json"):format(info.ld, loc)
  end
  return ("%s/%s/%s.php"):format(info.ld, loc, info.group)
end

-- arquivos/locales onde a chave existe
local function key_hits(info)
  local hits = {}
  for _, loc in ipairs(info.locales) do
    local path = path_for(info, loc)
    local status, val, line, col
    if info.is_json then
      status, val = lookup_json(path, info.key)
    else
      status, val = lookup_php(path, info.rest)
    end
    if status == "exists" then
      if info.is_json then
        line, col = locate_json(path, info.key)
      else
        line, col = locate_php(path, info.segs, info.rest)
      end
      hits[#hits + 1] = { loc = loc, path = path, line = line, col = col, value = val or "" }
    end
  end
  return hits
end

-- cria a chave no locale padrão
local function create_key(info, opts)
  local loc = info.locales[1]
  local path = path_for(info, loc)

  -- valor sugerido (com os props como :placeholder)
  local default = opts.default or info.key
  if not opts.default and not info.is_json then
    local last = info.segs[#info.segs]:gsub("_", " ")
    default = last:sub(1, 1):upper() .. last:sub(2)
    for _, p in ipairs(opts.props or {}) do
      default = default .. " :" .. p
    end
  end

  input({
    title = ("[%s] %s"):format(loc, info.key),
    footer = ("→ %s  ·  <CR> salva · <Esc> cancela"):format(vim.fn.fnamemodify(path, ":.")),
    default = default,
  }, function(v)
    if v == nil then
      return
    end -- desistiu: nada é alterado

    local ok, res
    if info.is_json then
      ok, res = add_json(path, info.key, v)
    else
      ok, res = add_php(path, info.segs, v)
    end
    if not ok then
      return notify(("[%s] %s"):format(loc, res), vim.log.levels.WARN)
    end

    if opts.on_saved then
      opts.on_saved()
    end

    if not opts.no_open and M.open_after_create then
      if info.is_json then
        local line, col = locate_json(path, info.key)
        open_at(path, line, col)
      else
        open_at(path, type(res) == "number" and res or nil)
      end
    end
  end)
end

-- opts = { key, default, props, no_open, on_saved }
local function add_flow(opts)
  local info = key_info(opts.key)
  if not info then
    return
  end

  -- usado pelo fluxo "texto -> chave": só precisa saber se existe no locale padrão
  if opts.no_open then
    local path = path_for(info, info.locales[1])
    local status
    if info.is_json then
      status = lookup_json(path, info.key)
    else
      status = lookup_php(path, info.rest)
    end
    if status == "exists" then
      if opts.on_saved then
        opts.on_saved()
      end
      return
    end
    return create_key(info, opts)
  end

  local hits = key_hits(info)
  if #hits == 0 then
    return create_key(info, opts)
  end
  if #hits == 1 then
    return open_at(hits[1].path, hits[1].line, hits[1].col)
  end

  -- existe em mais de um locale: escolher o arquivo
  local items = {}
  for _, h in ipairs(hits) do
    items[#items + 1] = { hit = h }
  end
  if hits[1].loc ~= info.locales[1] then
    items[#items + 1] = { create = true }
  end

  vim.ui.select(items, {
    prompt = "Traduções de " .. info.key .. ":",
    format_item = function(it)
      if it.create then
        return ("＋ Criar em [%s]"):format(info.locales[1])
      end
      local h = it.hit
      return ("[%s] %s:%s  %s"):format(h.loc, vim.fn.fnamemodify(h.path, ":."), h.line or "?", short(h.value, 80))
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.create then
      return create_key(info, opts)
    end
    open_at(choice.hit.path, choice.hit.line, choice.hit.col)
  end)
end

---------------------------------------------------------------------------
-- Fluxo 2: texto -> __('chave')
-- row: linha (0-based); s,e: colunas (1-based, inclusivas) do trecho a substituir
-- build(key) -> string que entra no lugar do trecho
---------------------------------------------------------------------------
local function replace_flow(row, s, e, text, build)
  if text == "" then
    return
  end
  build = build or default_build

  local bufnr = vim.api.nvim_get_current_buf()
  local orig_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local expected = orig_line:sub(s, e)

  local function replace_with(key)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    -- a linha não pode ter mudado enquanto o input estava aberto
    local cur = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    if cur:sub(s, e) ~= expected then
      return say("A linha mudou; substituição cancelada")
    end

    -- trecho dentro da chave de um __('...') existente: troca só a chave, sem embrulhar de novo
    local call = call_at(cur, "", s, e)
    if call and s >= call.ks and e <= call.ke then
      pcall(vim.api.nvim_buf_set_text, bufnr, row, call.ks, row, call.ke - 1, { esc(key) })
      return
    end

    pcall(vim.api.nvim_buf_set_text, bufnr, row, s - 1, row, e, { build(key) })
  end

  local root = find_root()
  local ld = lang_dir(root)
  local loc = sort_locales(list_locales(ld, false), default_locale(root))[1]
  if not loc then
    return notify("Nenhum locale encontrado em " .. ld, vim.log.levels.ERROR)
  end

  local cands = find_candidates(ld, loc, text)

  if #cands == 1 then
    return replace_with(cands[1])
  elseif #cands > 1 then
    return vim.ui.select(cands, { prompt = "Chaves com esse texto:" }, function(choice)
      if choice then
        replace_with(choice)
      end
    end)
  end

  -- não existe: pede o nome da chave (com autocomplete); só substitui depois que a tradução for salva
  input({
    title = ("Nova chave para '%s'"):format(short(text, 40)),
    footer = "<Tab> navega · <CR> aceita/ok · <Esc> cancela",
    complete = key_completer(ld, loc),
  }, function(key)
    key = key and vim.trim(key)
    if not key or key == "" then
      return
    end
    add_flow({
      key = key,
      default = text,
      no_open = true,
      on_saved = function()
        replace_with(key)
      end,
    })
  end)
end

---------------------------------------------------------------------------
-- Fluxo 3: dentro de um arquivo de tradução, chave -> onde ela é usada
---------------------------------------------------------------------------
-- o buffer atual é um arquivo de tradução? retorna caminho relativo à pasta lang
local function lang_rel_path(ld)
  local file = vim.fs.normalize(vim.api.nvim_buf_get_name(0))
  local prefix = vim.fs.normalize(ld) .. "/"
  if file:sub(1, #prefix) ~= prefix then
    return nil
  end
  local rel = file:sub(#prefix + 1)
  if rel:match("^vendor/") then
    return nil
  end
  if rel:match("%.json$") or rel:match("%.php$") then
    return rel
  end
end

local function opens_array(v)
  return v:match("^%[") ~= nil or v:match("^array%s*%(") ~= nil
end

local function php_key_line(l)
  local ind, _, key, rest = l:match("^(%s*)(['\"])(.-)%2%s*=>%s*(.*)$")
  if ind then
    return ind, key, rest
  end
end

local function json_key_on_line(line)
  local i = line:find('"', 1, true)
  if not i or not line:sub(1, i - 1):match("^%s*$") then
    return
  end
  local j = i + 1
  while j <= #line do
    local c = line:sub(j, j)
    if c == "\\" then
      j = j + 2
    elseif c == '"' then
      break
    else
      j = j + 1
    end
  end
  if j > #line then
    return
  end
  if not line:sub(j + 1):match("^%s*:") then
    return
  end
  local ok, key = pcall(vim.json.decode, line:sub(i, j))
  if ok and type(key) == "string" then
    return key
  end
end

-- chave completa sob o cursor em um arquivo de tradução; retorna key, is_array
local function lang_key_at_cursor(rel)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  if rel:match("%.json$") then
    local key = json_key_on_line(vim.api.nvim_get_current_line())
    return key, false
  end

  local group = rel:match("^[^/]+/(.+)%.php$") -- tenant/app
  if not group then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  -- linha da chave (a atual, ou a mais próxima acima em valores de várias linhas)
  local idx
  for i = lnum, math.max(1, lnum - 10), -1 do
    local l = lines[i]
    if l:match("^%s*[%]%)]") then
      break
    end
    if php_key_line(l) then
      idx = i
      break
    end
  end
  if not idx then
    return nil
  end

  local ind, key, rest = php_key_line(lines[idx])
  local parts = { key }
  local cur = #ind

  -- sobe pela indentação juntando os arrays pais
  for i = idx - 1, 1, -1 do
    local l = lines[i]
    if l:match("^return") then
      break
    end
    local pind, pkey, prest = php_key_line(l)
    if pind and #pind < cur and opens_array(prest) then
      table.insert(parts, 1, pkey)
      cur = #pind
    end
  end

  return group .. "." .. table.concat(parts, "."), opens_array(rest)
end

-- coluna (0-based) onde a chave aparece entre aspas; para arrays aceita também `chave.`
local function usage_col(text, key, is_array)
  local init = 1
  while true do
    local s, e = text:find(key, init, true)
    if not s then
      return
    end
    local before = s > 1 and text:sub(s - 1, s - 1) or ""
    local after = text:sub(e + 1, e + 1)
    if (before == "'" or before == '"') and (after == "'" or after == '"' or (is_array and after == ".")) then
      return s - 1
    end
    init = e + 1
  end
end

local function search_usages(root, ld, key, is_array)
  local cmd
  if vim.fn.executable("rg") == 1 then
    cmd = {
      "rg",
      "--line-number",
      "--no-heading",
      "--with-filename",
      "--color=never",
      "-F",
      "-g",
      "!vendor/**",
      "-g",
      "!node_modules/**",
      "-g",
      "!storage/**",
      "-e",
      key,
      ".",
    }
  elseif vim.fn.executable("grep") == 1 then
    cmd = {
      "grep",
      "-rnIF",
      "--exclude-dir=vendor",
      "--exclude-dir=node_modules",
      "--exclude-dir=storage",
      "--exclude-dir=.git",
      "-e",
      key,
      ".",
    }
  else
    say("Instale ripgrep (rg) para buscar usos")
    return nil
  end

  local ok, res = pcall(function()
    return vim.system(cmd, { cwd = root, text = true }):wait(15000)
  end)
  if not ok or not res then
    return {}
  end

  -- pasta lang relativa à raiz (para ignorar os próprios arquivos de tradução)
  local nroot, nld = vim.fs.normalize(root), vim.fs.normalize(ld)
  local rel_lang = nld:sub(1, #nroot + 1) == nroot .. "/" and nld:sub(#nroot + 2) or nil

  local items = {}
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    local file, lnum, text = line:match("^(.-):(%d+):(.*)$")
    if file then
      file = file:gsub("^%./", "")
      local in_lang = rel_lang and file:sub(1, #rel_lang + 1) == rel_lang .. "/"
      if not in_lang then
        local col = usage_col(text, key, is_array)
        if col then
          items[#items + 1] = { file = file, lnum = tonumber(lnum), col = col, text = short(text, 120) }
        end
      end
    end
  end

  table.sort(items, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.lnum < b.lnum
  end)
  return items
end

local function jump_to(root, it)
  open_at(root .. "/" .. it.file, it.lnum, it.col)
end

local function show_usages(root, key, items)
  if #items == 1 then
    return jump_to(root, items[1])
  end

  if M.usages_ui == "quickfix" then
    local qf = {}
    for _, it in ipairs(items) do
      qf[#qf + 1] = { filename = root .. "/" .. it.file, lnum = it.lnum, col = it.col + 1, text = it.text }
    end
    vim.fn.setqflist({}, " ", { title = "Usos de " .. key, items = qf })
    return vim.cmd("copen")
  end

  vim.ui.select(items, {
    prompt = "Usos de " .. key .. ":",
    format_item = function(it)
      return ("%s:%d  %s"):format(it.file, it.lnum, it.text)
    end,
  }, function(choice)
    if choice then
      jump_to(root, choice)
    end
  end)
end

---------------------------------------------------------------------------
-- Assistente de chave em modo insert
-- Dentro de __('...'), desliga outras fontes de completion naquele trecho e
-- mostra as chaves do mesmo local do arquivo de tradução:
--   __('tenant/app.events.join_event_now|')  ->  irmãs em tenant/app.events.*
--   continuar digitando / apagar parte do caminho filtra pelo que está antes do cursor
---------------------------------------------------------------------------
local assist = { active = false, buf = nil, list = nil, saved = nil, had = nil, comp = nil, ctx = nil, last = nil }
local ASSIST_KEYS = { "<Tab>", "<S-Tab>", "<Down>", "<Up>", "<C-n>", "<C-p>", "<CR>" }

local assist_refresh

-- lista logo abaixo do cursor (ou acima, se não houver espaço)
local function cursor_place(n, w)
  local win = vim.api.nvim_get_current_win()
  local pos = vim.api.nvim_win_get_cursor(win)
  local acol = assist.ctx and (assist.ctx.qs + 1) or (pos[2] + 1)
  local sp = vim.fn.screenpos(win, pos[1], acol)
  if not sp or sp.row == 0 then
    sp = { row = 1, col = 1 }
  end

  local below = vim.o.lines - vim.o.cmdheight - 2 - sp.row
  local above = sp.row - 3
  local h = math.min(n, MAXH)
  local row
  if below >= math.min(h, 4) or below >= above then
    h = math.max(1, math.min(h, below))
    row = sp.row
  else
    h = math.max(1, math.min(h, above))
    row = sp.row - h - 3
  end
  local col = math.max(0, math.min(sp.col - 1, vim.o.columns - w - 2))
  return row, col, h
end

local function assist_unbind()
  if not assist.saved then
    return
  end
  local buf, saved = assist.buf, assist.saved
  assist.saved = nil
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.api.nvim_buf_call(buf, function()
    for lhs, prev in pairs(saved) do
      pcall(vim.keymap.del, "i", lhs, { buffer = buf })
      if prev then
        pcall(vim.fn.mapset, "i", false, prev)
      end
    end
  end)
end

local function assist_stop()
  if not assist.active and not assist.saved and not (assist.list and assist.list:visible()) then
    return
  end
  assist_unbind()
  if assist.list then
    assist.list:close()
  end
  if assist.active and assist.buf and vim.api.nvim_buf_is_valid(assist.buf) then
    vim.b[assist.buf].completion = assist.had
  end
  assist.active, assist.buf, assist.had = false, nil, nil
  assist.comp, assist.ctx, assist.last = nil, nil, nil
end

-- aceita o item selecionado: troca a chave inteira (até a aspa de fechamento)
local function assist_accept()
  local item = assist.list and assist.list:current()
  if not item then
    return
  end

  local buf = assist.buf or vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local cx = key_context(vim.api.nvim_get_current_line(), pos[2])
  if not cx then
    return
  end

  local new = esc(item.word)
  local stop = cx.close and (cx.close - 1) or pos[2]
  pcall(vim.api.nvim_buf_set_text, buf, pos[1] - 1, cx.qs, pos[1] - 1, stop, { new })
  pcall(vim.api.nvim_win_set_cursor, 0, { pos[1], cx.qs + #new })
  assist_refresh(true)
end

-- mapeia as teclas enquanto a lista está visível; guarda e restaura mapeamentos locais anteriores
local function assist_bind(buf)
  if assist.saved then
    return
  end
  assist.saved = {}

  vim.api.nvim_buf_call(buf, function()
    for _, lhs in ipairs(ASSIST_KEYS) do
      local prev = vim.fn.maparg(lhs, "i", false, true)
      local is_local = type(prev) == "table" and prev.buffer == 1 and prev.lhs ~= nil
      assist.saved[lhs] = is_local and prev or false
    end
  end)

  local function map(lhs, fn)
    vim.keymap.set("i", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  for _, lhs in ipairs({ "<Tab>", "<C-n>", "<Down>" }) do
    map(lhs, function()
      assist.list:move(1)
    end)
  end
  for _, lhs in ipairs({ "<S-Tab>", "<C-p>", "<Up>" }) do
    map(lhs, function()
      assist.list:move(-1)
    end)
  end
  map("<CR>", function()
    if assist.list and assist.list.sel > 0 then
      assist_accept()
    else
      -- sem item selecionado: Enter normal
      assist_unbind()
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "m", false)
    end
  end)
end

assist_refresh = function(force)
  if not M.key_assist then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  if vim.fn.mode():sub(1, 1) ~= "i" then
    return assist_stop()
  end
  if vim.bo[buf].buftype ~= "" then
    return
  end

  local pos = vim.api.nvim_win_get_cursor(0)
  local cx = key_context(vim.api.nvim_get_current_line(), pos[2])
  if not cx then
    return assist_stop()
  end

  if assist.active and assist.buf ~= buf then
    assist_stop()
  end

  if not assist.comp then
    local root = find_root()
    local ld = lang_dir(root)
    local loc = sort_locales(list_locales(ld, false), default_locale(root))[1]
    if not loc then
      return
    end -- não é um projeto com traduções
    assist.comp = key_completer(ld, loc)
  end

  if not assist.active then
    assist.active, assist.buf, assist.had = true, buf, vim.b[buf].completion
    vim.b[buf].completion = false -- blink.cmp: desliga as outras fontes neste buffer
  end
  assist.ctx = cx

  -- fecha menus de outros plugins que já tenham aberto
  vim.schedule(function()
    local b = package.loaded["blink.cmp"]
    if b and b.is_visible and b.is_visible() then
      pcall(b.hide)
    end
    local c = package.loaded["cmp"]
    if c and c.visible and c.visible() then
      pcall(c.close)
    end
  end)

  local state = ("%d:%d:%s"):format(pos[1], cx.qs, cx.prefix)
  if not force and state == assist.last then
    return
  end
  assist.last = state

  local items, exact = {}, false
  for _, it in ipairs(assist.comp(cx.prefix)) do
    if it.word == cx.prefix then
      exact = true
    else
      items[#items + 1] = it
    end
  end

  -- chave já completa: mostra as outras chaves do mesmo local (irmãs)
  if exact then
    local parent = cx.prefix:match("^(.*[%./])") or ""
    items = {}
    for _, it in ipairs(assist.comp(parent)) do
      if it.word ~= cx.prefix then
        items[#items + 1] = it
      end
    end
  end

  assist.list = assist.list or new_list(cursor_place, 24)
  if #items == 0 then
    assist_unbind()
    assist.list:close()
    return
  end
  assist.list:set(items)
  assist_bind(buf)
end

-- ativa o assistente de modo insert (chamar uma vez, ex.: em config/keymaps.lua)
function M.setup()
  local group = vim.api.nvim_create_augroup("LaravelLangKeyAssist", { clear = true })
  if not M.key_assist then
    return
  end

  vim.api.nvim_create_autocmd({ "InsertEnter", "CursorMovedI", "TextChangedI" }, {
    group = group,
    pattern = "*.php",
    callback = function()
      assist_refresh(false)
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "WinLeave" }, {
    group = group,
    pattern = "*.php",
    callback = assist_stop,
  })
end

---------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------
-- Dentro de um arquivo de tradução: vai para onde a chave sob o cursor é usada.
function M.usages()
  local root = find_root()
  local ld = lang_dir(root)

  local rel = lang_rel_path(ld)
  if not rel then
    return say("Este buffer não é um arquivo de tradução")
  end

  local key, is_array = lang_key_at_cursor(rel)
  if not key then
    return say("Nenhuma chave de tradução sob o cursor")
  end

  local items = search_usages(root, ld, key, is_array)
  if not items then
    return
  end
  if #items == 0 then
    return say("Nenhum uso encontrado para " .. key)
  end

  show_usages(root, key, items)
end

-- Modo normal:
--   em arquivo de tradução    -> vai para onde a chave é usada
--   cursor sobre __('chave')  -> vai até a tradução (lista se houver em vários locales; cria se não existir)
--   cursor sobre uma string   -> troca por __('chave') (ou cria uma nova)
function M.add()
  if lang_rel_path(lang_dir(find_root())) then
    return M.usages()
  end

  local pos = vim.api.nvim_win_get_cursor(0)
  local row0, col = pos[1] - 1, pos[2] + 1
  local line = vim.api.nvim_get_current_line()

  local call = call_at(line, following_lines(row0), col)
  if call then
    return add_flow({ key = call.key, props = call.props })
  end

  local s, e, text, build = plan_replacement(line, is_blade_buf(), col, col, true)
  if s then
    return replace_flow(row0, s, e, text, build)
  end

  say("Nada para traduzir sob o cursor")
end

-- Modo visual (uma linha):
--   seleção sobre uma chave __('...')  -> vai até a tradução (ou cria)
--   seleção dentro de uma string       -> troca o trecho por __('chave')
--   Blade: texto solto -> {{ __('chave') }}
function M.add_visual()
  local mode = vim.fn.mode()
  local p1, p2 = vim.fn.getpos("v"), vim.fn.getpos(".")
  vim.cmd("normal! \27") -- sai do modo visual

  if lang_rel_path(lang_dir(find_root())) then
    return M.usages()
  end

  if p1[2] ~= p2[2] then
    return say("Selecione apenas uma linha")
  end

  local lnum = p1[2]
  local row0 = lnum - 1
  local line = vim.fn.getline(lnum)
  local s, e = math.min(p1[3], p2[3]), math.max(p1[3], p2[3])

  if mode == "V" then
    s, e = 1, #line
  else
    e = math.min(e, #line)
    -- inclui o último caractere inteiro (UTF-8)
    e = vim.fn.byteidx(line, vim.fn.charidx(line, e - 1) + 1)
  end

  local seg = line:sub(s, e)
  if seg:match("^%s*$") then
    return
  end

  -- ignora espaços nas pontas da seleção
  local lead, trail = #seg:match("^%s*"), #seg:match("%s*$")
  s, e = s + lead, e - trail

  -- 1) seleção sobre uma chave de tradução: navega / cria
  local call = call_at(line, following_lines(row0), s, e)
  if call then
    return add_flow({ key = call.key, props = call.props })
  end

  -- 2) texto -> chave
  local rs, re, text, build = plan_replacement(line, is_blade_buf(), s, e, false)
  if not rs then
    return say("Selecione um texto dentro de uma string")
  end
  replace_flow(row0, rs, re, text, build)
end

M.ui = { input = input, find_root = find_root }

return M
