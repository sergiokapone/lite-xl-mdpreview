-- mod-version:3
--
-- mdpreview: rendered Markdown preview in a Lite XL tab (Ctrl+Shift+M).
--
-- Headings, bold/italic, `inline code`, fenced code blocks, bullet/numbered
-- lists, block quotes, horizontal rules, simple tables and clickable links.
-- Links open in the browser (http/https) or in the editor / default program
-- (relative files). The preview follows edits live. No external tools needed.
-- LaTeX math ($..$, $$..$$, \(..\), \[..\]) is approximated with Unicode and small raised/lowered
-- text; Ctrl+Alt+M ("Markdown: Open in Browser") renders the file exactly with pandoc + MathJax.
-- Not supported: images (shown as a "[img: alt]" link), raw HTML.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local DocView = require "core.docview"

config.plugins.mdpreview = common.merge({
  max_width = 900 * SCALE, -- text column width limit (0 = use all the width)
  pandoc = "",             -- path to pandoc for "Markdown: Open in Browser" ("" = auto-detect)
}, config.plugins.mdpreview)

-------------------------------------------------------------------- math ----
-- LaTeX math ($..$, \(..\), $$..$$, \[..\]) is approximated: Greek letters and symbols become
-- Unicode, fractions "a/b", roots "√x", and super/subscripts are drawn as smaller raised/lowered
-- text (the font has no Unicode super/subscript letters). For exact output use
-- "Markdown: Open in Browser" (pandoc + MathJax).

local GREEK = {
  alpha="α", beta="β", gamma="γ", delta="δ", epsilon="ε", varepsilon="ε", zeta="ζ", eta="η", theta="θ",
  vartheta="θ", iota="ι", kappa="κ", lambda="λ", mu="μ", nu="ν", xi="ξ", omicron="ο", pi="π", varpi="ϖ",
  rho="ρ", varrho="ρ", sigma="σ", varsigma="ς", tau="τ", upsilon="υ", phi="φ", varphi="φ", chi="χ",
  psi="ψ", omega="ω", Gamma="Γ", Delta="Δ", Theta="Θ", Lambda="Λ", Xi="Ξ", Pi="Π", Sigma="Σ",
  Upsilon="Υ", Phi="Φ", Psi="Ψ", Omega="Ω",
}

local SYM = {
  times="×", cdot="·", pm="±", mp="∓", div="÷", ast="*", star="⋆", circ="∘", bullet="•", oplus="⊕",
  otimes="⊗", odot="⊙", ominus="⊖", leq="≤", le="≤", geq="≥", ge="≥", neq="≠", ne="≠", approx="≈",
  sim="∼", simeq="≃", cong="≅", equiv="≡", propto="∼", ll="≪", gg="≫", ["in"]="∈", notin="∉",
  subset="⊂", supset="⊃", subseteq="⊆", supseteq="⊇", cup="∪", cap="∩", emptyset="∅", varnothing="∅",
  forall="∀", exists="∃", neg="¬", lnot="¬", land="∧", lor="∨", wedge="∧", vee="∨", to="→",
  rightarrow="→", leftarrow="←", gets="←", leftrightarrow="↔", Rightarrow="⇒", Leftarrow="⇐",
  Leftrightarrow="⇔", iff="⇔", implies="⇒", Longrightarrow="⇒", longrightarrow="⟶", longleftarrow="⟵",
  mapsto="↦", hookrightarrow="↪", uparrow="↑", downarrow="↓", infty="∞", partial="∂", nabla="∇",
  hbar="ħ", ell="ℓ", aleph="aleph", sum="∑", prod="∏", int="∫", iint="∫∫", iiint="∫∫∫", oint="∫",
  ldots="…", cdots="⋯", dots="…", vdots="⋮", ddots="⋱", angle="∠", perp="⊥", parallel="∥",
  degree="°", prime="′", langle="⟨", rangle="⟩", lbrace="{", rbrace="}", lbrack="[", rbrack="]",
  lceil="⌈", rceil="⌉", lfloor="⌊", rfloor="⌋", therefore="∴", because="∵", Box="□", square="□",
  triangle="△", dagger="†", ddagger="‡", mid="∣", vert="|", Vert="‖", setminus="\\", lt="<", gt=">",
  quad="  ", qquad="    ", AA="Å", Re="Re", Im="Im",
}
SYM["angle"] = "angle "

local FUNCS = {}
for w in ("sin cos tan cot sec csc arcsin arccos arctan sinh cosh tanh coth log ln lg exp lim max min sup inf det dim ker deg gcd arg Pr mod sgn"):gmatch("%a+") do FUNCS[w] = true end

local ACCENT = { hat = "\u{302}", widehat = "\u{302}", bar = "\u{304}", overline = "\u{304}", tilde = "\u{303}",
                 widetilde = "\u{303}", dot = "\u{307}", ddot = "\u{308}" }
local BB = { R = "ℝ", N = "ℕ", Z = "ℤ", Q = "ℚ", C = "ℂ", P = "ℙ", H = "ℍ" }
local ENV_OPEN  = { pmatrix = "(", bmatrix = "[", vmatrix = "|", Vmatrix = "‖", Bmatrix = "{", cases = "{ " }
local ENV_CLOSE = { pmatrix = ")", bmatrix = "]", vmatrix = "|", Vmatrix = "‖", Bmatrix = "}" }

local CHAR = "^[\1-\127\194-\244][\128-\191]*"

-- Reads one argument ({group}, \command or a single character) starting at byte i (after spaces).
local function read_arg(s, i)
  while s:sub(i, i):match("^%s$") do i = i + 1 end
  local c = s:sub(i, i)
  if c == "" then return "", i end
  if c == "{" then
    local depth, j = 1, i + 1
    while j <= #s and depth > 0 do
      local d = s:sub(j, j)
      if d == "{" then depth = depth + 1 elseif d == "}" then depth = depth - 1 end
      j = j + 1
    end
    return s:sub(i + 1, j - 2), j
  elseif c == "\\" then
    local name = s:match("^\\%a+", i) or s:sub(i, i + 1)
    return name, i + #name
  end
  local ch = s:match(CHAR, i) or c
  return ch, i + #ch
end

local conv
local function flat(arg)
  local t = {}
  for _, sg in ipairs(conv(arg, {}, {})) do t[#t + 1] = sg.t end
  return table.concat(t)
end

local function wrap(x)
  if (utf8.len(x) or #x) <= 1 or x:match("^[%w%.]+$") then return x end
  return "(" .. x .. ")"
end

-- Converts a LaTeX math string into a list of segments {t=text, script="sup"|"sub", bold=, upright=}.
conv = function(s, ctx, out)
  local i = 1
  local function add(t, extra)
    if t == "" then return end
    local seg = { t = t, script = ctx.script, bold = ctx.bold, upright = ctx.upright }
    if extra then for k, v in pairs(extra) do seg[k] = v end end
    out[#out + 1] = seg
  end
  local function sub(arg, over)
    local c2 = {}
    for k, v in pairs(ctx) do c2[k] = v end
    if over then for k, v in pairs(over) do c2[k] = v end end
    conv(arg, c2, out)
  end

  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" then
      local name = s:match("^\\(%a+)", i)
      if not name then
        local ch = s:sub(i + 1, i + 1)
        i = i + 2
        if ch == "," or ch == ";" or ch == ":" or ch == " " then add(" ")
        elseif ch == "!" then -- negative thin space: nothing
        elseif ch == "|" then add("‖")
        elseif ch == "\\" then add("; ")
        else add(ch) end
      else
        i = i + 1 + #name
        if name == "frac" or name == "dfrac" or name == "tfrac" or name == "cfrac" then
          local a, j = read_arg(s, i); local b, j2 = read_arg(s, j); i = j2
          local fa, fb = flat(a), flat(b)
          if wrap(fa) ~= fa then add("(") end
          sub(a)
          if wrap(fa) ~= fa then add(")") end
          add("/")
          if wrap(fb) ~= fb then add("(") end
          sub(b)
          if wrap(fb) ~= fb then add(")") end
        elseif name == "binom" then
          local a, j = read_arg(s, i); local b, j2 = read_arg(s, j); i = j2
          add("(" .. flat(a) .. ", " .. flat(b) .. ")")
        elseif name == "sqrt" then
          local n
          if s:sub(i, i) == "[" then
            local e = s:find("]", i, true)
            if e then n = s:sub(i + 1, e - 1); i = e + 1 end
          end
          local a, j = read_arg(s, i); i = j
          local root = (n == "3" and "∛") or (n == "4" and "∜") or (n and (flat(n) .. "√")) or "√"
          if root == "∛" then root = "³√" elseif root == "∜" then root = "⁴√" end
          local fa = flat(a)
          add(root)
          if wrap(fa) ~= fa then add("(") end
          sub(a)
          if wrap(fa) ~= fa then add(")") end
        elseif name == "text" or name == "mathrm" or name == "textrm" or name == "operatorname" or name == "rm" or name == "mbox" then
          local a, j = read_arg(s, i); i = j; sub(a, { upright = true })
        elseif name == "mathbf" or name == "textbf" or name == "boldsymbol" or name == "bm" or name == "bf" or name == "vec" then
          local a, j = read_arg(s, i); i = j; sub(a, { bold = true, upright = true })
        elseif name == "mathbb" then
          local a, j = read_arg(s, i); i = j
          add((a:gsub("%a", function(l) return BB[l] or l end)), { upright = true })
        elseif name == "mathit" or name == "mathcal" or name == "mathscr" or name == "mathfrak" or name == "mathsf" or name == "boldmath" then
          local a, j = read_arg(s, i); i = j; sub(a)
        elseif ACCENT[name] then
          local a, j = read_arg(s, i); i = j
          sub(a); add(ACCENT[name], { upright = true })
        elseif name == "left" or name == "right" or name == "big" or name == "Big" or name == "bigg" or name == "Bigg" then
          if s:sub(i, i) == "." then i = i + 1 end
        elseif name == "begin" then
          local env, j = read_arg(s, i); i = j
          if env == "array" then local _, j2 = read_arg(s, i); i = j2 end
          add(ENV_OPEN[env] or "")
        elseif name == "end" then
          local env, j = read_arg(s, i); i = j
          add(ENV_CLOSE[env] or "")
        elseif name == "tag" then
          local a, j = read_arg(s, i); i = j; add("   (" .. flat(a) .. ")", { upright = true })
        elseif name == "label" or name == "hspace" or name == "vspace" or name == "color" or name == "pagecolor" then
          local _, j = read_arg(s, i); i = j
        elseif name == "displaystyle" or name == "textstyle" or name == "limits" or name == "nolimits" or name == "nonumber"
            or name == "notag" or name == "scriptstyle" then
          -- no visible output
        elseif name == "not" then
          add("̸")
        elseif GREEK[name] then add(GREEK[name], { upright = true })
        elseif FUNCS[name] then add(name, { upright = true })
        elseif SYM[name] then add(SYM[name], { upright = true })
        else add(name, { upright = true }) end
      end
    elseif c == "^" or c == "_" then
      local arg, j = read_arg(s, i + 1); i = j
      local kind = c == "^" and "sup" or "sub"
      if arg == "\\circ" and kind == "sup" then add("°", { script = false })
      elseif arg == "\\prime" and kind == "sup" then add("′")
      elseif ctx.script then sub(arg) -- nested scripts: same small size, no further shifting
      else sub(arg, { script = kind }) end
    elseif c == "{" or c == "}" then
      i = i + 1
    elseif c == "&" or c == "~" then
      add(" "); i = i + 1
    elseif c == "-" then
      add("−"); i = i + 1
    elseif c == "'" then
      add("′"); i = i + 1
    elseif c:match("%s") then
      local e = s:find("%S", i) or (#s + 1)
      add(" "); i = e
    else
      local ch = s:match(CHAR, i) or c
      -- batch plain characters together
      local e = s:find("[\\%^_{}&~%-'%s]", i)
      local chunk = s:sub(i, (e or #s + 1) - 1)
      if chunk == "" then chunk = ch end
      add(chunk); i = i + #chunk
    end
  end
  return out
end

-- Spans for the preview: {text=, math=true, italic=, bold=, script=}
local function math_spans(src)
  local spans = {}
  for _, sg in ipairs(conv(src, {}, {})) do
    local script = sg.script or nil
    if sg.upright or sg.bold then
      spans[#spans + 1] = { text = sg.t, math = true, bold = sg.bold, script = script }
    else
      local pos = 1
      while pos <= #sg.t do
        local a, b = sg.t:find("^[A-Za-z]+", pos)
        if a then
          spans[#spans + 1] = { text = sg.t:sub(a, b), math = true, italic = true, script = script }
        else
          b = (sg.t:find("[A-Za-z]", pos) or #sg.t + 1) - 1
          spans[#spans + 1] = { text = sg.t:sub(pos, b), math = true, script = script }
        end
        pos = b + 1
      end
    end
  end
  return spans
end

-- Display math may contain several lines separated by \\ (not for matrices/cases).
local function math_lines(src)
  if src:find("matrix") or src:find("cases") or src:find("{array}") then return { src } end
  local lines = {}
  src = src:gsub("\\begin%s*%b{}", ""):gsub("\\end%s*%b{}", "")
  for part in (src .. "\\\\"):gmatch("(.-)\\\\") do
    if part:find("%S") then lines[#lines + 1] = part end
  end
  if #lines == 0 then lines[1] = src end
  return lines
end

------------------------------------------------------------------ inline ----

-- Returns a list of spans {text=, bold=, italic=, code=, link=}.
local function parse_inline(s, flags, out)
  out = out or {}
  flags = flags or {}
  local function emit(text, extra)
    if text == "" then return end
    local sp = { text = text, bold = flags.bold, italic = flags.italic, code = flags.code, link = flags.link }
    if extra then for k, v in pairs(extra) do sp[k] = v end end
    out[#out + 1] = sp
  end
  local function sub(inner, extra)
    local nf = {}
    for k, v in pairs(flags) do nf[k] = v end
    for k, v in pairs(extra) do nf[k] = v end
    parse_inline(inner, nf, out)
  end

  local pos = 1
  while pos <= #s do
    -- find the earliest construct
    local best, bs, be, c1, c2
    local function try(name, pat)
      local a, b, x, y = s:find(pat, pos)
      if a and (not bs or a < bs) then best, bs, be, c1, c2 = name, a, b, x, y end
    end
    try("code", "`([^`]+)`")
    try("math", "%$%$(.-)%$%$")
    try("math", "\\%[(.-)\\%]")
    try("math", "\\%((.-)\\%)")
    do -- $inline math$: not "$5 and $6", not escaped \$
      local from = pos
      while true do
        local a, b, x = s:find("%$([^%$%s][^%$]-)%$", from)
        if not a then break end
        if s:sub(a - 1, a - 1) == "\\" or x:match("%s$") or s:sub(b + 1, b + 1):match("%d") then
          from = a + 1
        else
          if not bs or a < bs then best, bs, be, c1, c2 = "math", a, b, x, nil end
          break
        end
      end
    end
    try("img", "!%[([^%]]*)%]%(([^%)]+)%)")
    try("link", "%[([^%]]+)%]%(([^%)]+)%)")
    try("bold", "%*%*(.-)%*%*")
    try("bold", "__(.-)__")
    try("italic", "%*([^%*%s][^%*]-)%*")
    try("url", "(https?://[^%s<>%)%]]+)")
    if not best then emit(s:sub(pos)) break end
    emit(s:sub(pos, bs - 1))
    if best == "code" then emit(c1, { code = true })
    elseif best == "math" then
      for _, sp in ipairs(math_spans(c1)) do
        emit(sp.text, { math = true, italic = sp.italic, bold = sp.bold, script = sp.script })
      end
    elseif best == "img" then emit("[img: " .. (c1 ~= "" and c1 or c2) .. "]", { link = c2 })
    elseif best == "link" then sub(c1, { link = c2 })
    elseif best == "bold" then sub(c1, { bold = true })
    elseif best == "italic" then sub(c1, { italic = true })
    elseif best == "url" then emit(c1, { link = c1 }) end
    pos = be + 1
  end
  return out
end

------------------------------------------------------------------ blocks ----

local function split_row(line)
  local cells = {}
  line = line:gsub("^%s*|", ""):gsub("|%s*$", "")
  for cell in (line .. "|"):gmatch("(.-)|") do cells[#cells + 1] = cell:match("^%s*(.-)%s*$") end
  return cells
end

local function plain(s)
  local t = {}
  for _, sp in ipairs(parse_inline(s)) do t[#t + 1] = sp.text end
  return table.concat(t)
end

-- A line that starts display math ($$ or \[) and is not "$$x$$ followed by more text".
local function display_start(l)
  local open = l:match("^%s*(%$%$)") or l:match("^%s*(\\%[)")
  if not open then return false end
  local rest = l:gsub("^%s*" .. (open == "$$" and "%$%$" or "\\%["), "")
  local close = open == "$$" and "%$%$" or "\\%]"
  local a, b = rest:find(close)
  if a and rest:sub(b + 1):find("%S") then return false end
  return true
end

local function parse_blocks(text)
  local blocks, lines = {}, {}
  for l in (text:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  local i, para = 1, {}
  local function flush()
    if #para > 0 then blocks[#blocks + 1] = { t = "p", text = table.concat(para, " ") } para = {} end
  end
  -- skip YAML front matter
  if lines[1] == "---" then
    for j = 2, #lines do if lines[j] == "---" then i = j + 1 break end end
  end
  while i <= #lines do
    local l = lines[i]
    local fence = l:match("^%s*(```)") or l:match("^%s*(~~~)")
    if fence then
      flush()
      local code = {}
      i = i + 1
      while i <= #lines and not lines[i]:match("^%s*" .. fence) do code[#code + 1] = lines[i] i = i + 1 end
      blocks[#blocks + 1] = { t = "code", lines = code }
    elseif l:match("^%s*$") then
      flush()
    elseif display_start(l) then
      flush()
      local open = l:match("^%s*(%$%$)") or l:match("^%s*(\\%[)")
      local close = open == "$$" and "%$%$" or "\\%]"
      local rest = (l:gsub("^%s*" .. (open == "$$" and "%$%$" or "\\%["), ""))
      local cpos = rest:find(close)
      local body
      if cpos then
        body = rest:sub(1, cpos - 1)
      else
        local buf = { rest }
        i = i + 1
        while i <= #lines do
          local cp = lines[i]:find(close)
          if cp then buf[#buf + 1] = lines[i]:sub(1, cp - 1) break end
          buf[#buf + 1] = lines[i]
          i = i + 1
        end
        body = table.concat(buf, "\n")
      end
      blocks[#blocks + 1] = { t = "math", text = body }
    elseif l:match("^#+%s") then
      flush()
      local h, txt = l:match("^(#+)%s+(.-)%s*#*$")
      blocks[#blocks + 1] = { t = "h", level = math.min(#h, 6), text = txt }
    elseif l:match("^%s*%-%-%-+%s*$") or l:match("^%s*%*%*%*+%s*$") or l:match("^%s*___+%s*$") then
      flush()
      blocks[#blocks + 1] = { t = "hr" }
    elseif l:match("^%s*>") then
      flush()
      local q = {}
      while i <= #lines and lines[i]:match("^%s*>") do q[#q + 1] = lines[i]:gsub("^%s*>%s?", "") i = i + 1 end
      i = i - 1
      blocks[#blocks + 1] = { t = "quote", text = table.concat(q, " ") }
    elseif l:match("^%s*[%-%*%+]%s+") or l:match("^%s*%d+[%.%)]%s+") then
      flush()
      local indent, marker, txt = l:match("^(%s*)([%-%*%+])%s+(.*)$")
      if not marker then indent, marker, txt = l:match("^(%s*)(%d+[%.%)])%s+(.*)$") end
      if marker:match("^[%-%*%+]$") then marker = "•" end
      -- continuation lines (indented, not a new item)
      while lines[i + 1] and lines[i + 1]:match("^%s+%S") and not lines[i + 1]:match("^%s*[%-%*%+]%s+")
            and not lines[i + 1]:match("^%s*%d+[%.%)]%s+") do
        i = i + 1
        txt = txt .. " " .. lines[i]:match("^%s*(.-)$")
      end
      blocks[#blocks + 1] = { t = "li", level = math.floor(#indent:gsub("\t", "  ") / 2), marker = marker, text = txt }
    elseif l:match("^%s*|") and lines[i + 1] and lines[i + 1]:match("^%s*|?[%s%-:|]+$") and lines[i + 1]:find("%-") then
      flush()
      local rows = { split_row(l) }
      i = i + 2
      while i <= #lines and lines[i]:match("^%s*|") do rows[#rows + 1] = split_row(lines[i]) i = i + 1 end
      i = i - 1
      blocks[#blocks + 1] = { t = "table", rows = rows }
    else
      para[#para + 1] = l:match("^%s*(.-)%s*$")
    end
    i = i + 1
  end
  flush()
  return blocks
end

------------------------------------------------------------------- view -----

local PreviewView = View:extend()
function PreviewView:__tostring() return "MdPreviewView" end
PreviewView.context = "session"

function PreviewView:new(doc)
  PreviewView.super.new(self)
  self.doc = doc
  self.scrollable = true
  self.items = {}
  self.content_h = 0
  self.fonts = {}
  self.last_change, self.last_width, self.last_size = -1, -1, -1
  self.hover = nil
end

function PreviewView:get_name()
  local n = self.doc:get_name():match("([^/\\]+)$") or "?"
  return "Preview: " .. n
end

function PreviewView:get_scrollable_size() return self.content_h + style.padding.y * 4 end

function PreviewView:font(kind, bold, italic, scale)
  local key = kind .. tostring(bold) .. tostring(italic) .. scale
  local f = self.fonts[key]
  if not f then
    local base = kind == "code" and style.code_font or style.font
    f = base:copy(base:get_size() * scale, { bold = bold or nil, italic = italic or nil })
    self.fonts[key] = f
  end
  return f
end

-- Lays out all blocks for the current width into self.items.
function PreviewView:layout()
  local W = self.size.x
  local pad = style.padding.x * 2
  local maxw = config.plugins.mdpreview.max_width
  local colw = W - pad * 2
  if maxw and maxw > 0 and colw > maxw then colw = maxw end
  local left = pad + math.max(0, (W - pad * 2 - colw) / 2)
  local right = left + colw

  local items, y = {}, style.padding.y * 2
  local base_h = style.font:get_height()
  local text_color = style.text
  local link_color = style.syntax["function"] or style.accent
  local math_color = style.syntax["number"] or style.accent
  local blocks = parse_blocks(self.doc:get_text(1, 1, math.huge, math.huge))

  -- word-wrapped rich text; returns the new y
  local function flow(spans, x0, xmax, y0, scale, color, force_bold)
    local x, line, lh = x0, {}, 0
    local top_extra, bot_extra = 0, 0
    local function flush_line()
      for _, it in ipairs(line) do
        local bottom = y0 + top_extra + lh
        if it.script == "sup" then it.y = bottom - it.h - 0.35 * it.nh
        elseif it.script == "sub" then it.y = bottom - it.h + 0.2 * it.nh
        else it.y = bottom - it.h end
        items[#items + 1] = it
      end
      y0, x, line, lh = y0 + top_extra + lh + bot_extra, x0, {}, 0
      top_extra, bot_extra = 0, 0
    end
    for _, sp in ipairs(spans) do
      local font = self:font(sp.code and "code" or "ui", sp.bold or force_bold, sp.italic, scale * (sp.script and 0.7 or 1))
      local fh = font:get_height()
      local nh = sp.script and self:font("ui", false, false, scale):get_height() or fh
      local col = sp.math and math_color or (sp.link and link_color or color)
      local function put(word)
        local w = font:get_width(word)
        if x + w > xmax and x > x0 and not word:match("^%s+$") then
          flush_line()
        end
        if not (x == x0 and word:match("^%s+$")) then
          line[#line + 1] = { text = word, font = font, color = col, x = x, w = w, h = fh, link = sp.link, code = sp.code,
                              script = sp.script, nh = nh }
          x = x + w
          lh = math.max(lh, nh)
          if sp.script == "sup" then top_extra = math.max(top_extra, 0.1 * nh)
          elseif sp.script == "sub" then bot_extra = math.max(bot_extra, 0.2 * nh) end
        end
      end
      for word, space in (sp.text .. " "):sub(1, -2):gmatch("(%S*)(%s*)") do
        if word ~= "" then put(word) end
        if space ~= "" then put(" ") end
      end
    end
    if lh == 0 then lh = base_h * scale end
    flush_line()
    return y0
  end

  local hscale = { 2.0, 1.6, 1.35, 1.15, 1.05, 1.0 }
  for _, b in ipairs(blocks) do
    if b.t == "h" then
      y = y + base_h * 0.4
      y = flow(parse_inline(b.text), left, right, y, hscale[b.level], style.text, true)
      if b.level <= 2 then
        items[#items + 1] = { rect = true, x = left, y = y + 2, w = colw, h = 1, color = style.dim }
        y = y + 4
      end
      y = y + base_h * 0.4
    elseif b.t == "p" then
      y = flow(parse_inline(b.text), left, right, y, 1, text_color) + base_h * 0.6
    elseif b.t == "math" then
      local dscale = 1.1
      for _, ml in ipairs(math_lines(b.text)) do
        local spans = math_spans(ml)
        local w = 0
        for _, sp in ipairs(spans) do
          local f = self:font("ui", sp.bold, sp.italic, dscale * (sp.script and 0.7 or 1))
          w = w + f:get_width(sp.text)
        end
        local x0 = w < colw and (left + (colw - w) / 2) or left
        y = flow(spans, x0, w < colw and (x0 + w + 20) or right, y, dscale, text_color) + base_h * 0.1
      end
      y = y + base_h * 0.5
    elseif b.t == "quote" then
      local y0 = y
      y = flow(parse_inline(b.text), left + 16 * SCALE, right, y, 1, style.dim)
      items[#items + 1] = { rect = true, x = left, y = y0, w = 3 * SCALE, h = y - y0, color = style.accent }
      y = y + base_h * 0.6
    elseif b.t == "li" then
      local x0 = left + b.level * 24 * SCALE
      local mfont = self:font("ui", false, false, 1)
      items[#items + 1] = { text = b.marker, font = mfont, color = style.accent, x = x0, y = y, w = 0, h = base_h }
      y = flow(parse_inline(b.text), x0 + 24 * SCALE, right, y, 1, text_color) + base_h * 0.15
    elseif b.t == "code" then
      local font = self:font("code", false, false, 1)
      local fh = font:get_height()
      local h = #b.lines * fh + 12 * SCALE
      items[#items + 1] = { rect = true, x = left, y = y, w = colw, h = h, color = style.line_highlight }
      for k, l in ipairs(b.lines) do
        items[#items + 1] = { text = l:gsub("\t", "    "), font = font, color = style.syntax["string"] or text_color,
                              x = left + 8 * SCALE, y = y + 6 * SCALE + (k - 1) * fh, w = 0, h = fh }
      end
      y = y + h + base_h * 0.6
    elseif b.t == "hr" then
      items[#items + 1] = { rect = true, x = left, y = y + base_h * 0.4, w = colw, h = 2, color = style.dim }
      y = y + base_h
    elseif b.t == "table" then
      local widths = {}
      for _, r in ipairs(b.rows) do
        for c, cell in ipairs(r) do widths[c] = math.max(widths[c] or 0, utf8.len(plain(cell)) or #cell) end
      end
      local font = self:font("code", false, false, 1)
      local bfont = self:font("code", true, false, 1)
      local fh = font:get_height()
      local h = #b.rows * fh + 12 * SCALE
      items[#items + 1] = { rect = true, x = left, y = y, w = colw, h = h, color = style.line_highlight }
      for ri, r in ipairs(b.rows) do
        local parts = {}
        for c = 1, #widths do
          local t = plain(r[c] or "")
          parts[#parts + 1] = t .. string.rep(" ", widths[c] - (utf8.len(t) or #t))
        end
        items[#items + 1] = { text = "| " .. table.concat(parts, " | ") .. " |", font = ri == 1 and bfont or font,
                              color = ri == 1 and style.accent or text_color,
                              x = left + 8 * SCALE, y = y + 6 * SCALE + (ri - 1) * fh, w = 0, h = fh }
      end
      y = y + h + base_h * 0.6
    end
  end
  self.items, self.content_h = items, y
end

function PreviewView:update()
  local cid = self.doc:get_change_id()
  if cid ~= self.last_change or self.size.x ~= self.last_width or style.font:get_size() ~= self.last_size then
    if self.size.x > 0 then
      if style.font:get_size() ~= self.last_size then self.fonts = {} end
      self.last_change, self.last_width, self.last_size = cid, self.size.x, style.font:get_size()
      self:layout()
      core.redraw = true
    end
  end
  PreviewView.super.update(self)
end

local function link_at(self, x, y)
  local ox, oy = self:get_content_offset()
  for _, it in ipairs(self.items) do
    if it.link and x >= ox + it.x and x < ox + it.x + it.w and y >= oy + it.y and y < oy + it.y + it.h then
      return it.link
    end
  end
end

function PreviewView:on_mouse_moved(x, y, ...)
  PreviewView.super.on_mouse_moved(self, x, y, ...)
  self.cursor = link_at(self, x, y) and "hand" or "arrow"
end

local function open_external(target)
  local cmd
  if PLATFORM == "Windows" then cmd = { "cmd", "/c", "start", "", target }
  elseif PLATFORM == "Mac OS X" then cmd = { "open", target }
  else cmd = { "xdg-open", target } end
  pcall(process.start, cmd)
end

function PreviewView:on_mouse_pressed(button, x, y, clicks)
  if PreviewView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if button ~= "left" then return end
  local link = link_at(self, x, y)
  if not link then return end
  if link:match("^%a[%w+.-]*://") or link:match("^mailto:") then
    open_external(link)
  elseif link:sub(1, 1) ~= "#" then
    local dir = self.doc.abs_filename and self.doc.abs_filename:match("^(.*)[/\\][^/\\]*$")
    local path = link:gsub("#.*$", ""):gsub("%%20", " ")
    if not path:match("^%a:") and not path:match("^[/\\]") and dir then path = dir .. PATHSEP .. path end
    local ext = path:lower():match("%.(%w+)$")
    if ext == "md" or ext == "markdown" or ext == "txt" or ext == "lua" then
      core.try(function() core.root_view:open_doc(core.open_doc(path)) end)
    else
      open_external(path)
    end
  end
  return true
end

function PreviewView:draw()
  self:draw_background(style.background)
  local ox, oy = self:get_content_offset()
  local top, bottom = self.position.y, self.position.y + self.size.y
  for _, it in ipairs(self.items) do
    local y = oy + it.y
    if y + it.h >= top and y <= bottom then
      if it.rect then
        renderer.draw_rect(ox + it.x, y, it.w, it.h, it.color)
      else
        if it.code and not it.link then
          renderer.draw_rect(ox + it.x - 2, y, it.w + 4, it.h, style.line_highlight)
        end
        renderer.draw_text(it.font, it.text, ox + it.x, y, it.color)
        if it.link then renderer.draw_rect(ox + it.x, y + it.h - 2, it.w, 1, it.color) end
      end
    end
  end
  self:draw_scrollbar()
end

----------------------------------------------------------------- commands ----

local function find_preview(doc)
  for _, v in ipairs(core.root_view.root_node:get_children()) do
    if v:is(PreviewView) and v.doc == doc then return v end
  end
end

command.add(function()
  local v = core.active_view
  if v:is(PreviewView) then return true, v.doc end
  if not v:is(DocView) then return false end
  local name = (v.doc.filename or ""):lower()
  local md = name:match("%.md$") or name:match("%.markdown$") or name:match("%.mdx$") or name:match("%.mkd$")
  return md ~= nil, v.doc
end, (function()
  local function toggle(doc)
    local existing = find_preview(doc)
    if existing then
      existing.node = core.root_view.root_node:get_node_for_view(existing)
      existing.node:close_view(core.root_view.root_node, existing)
      return
    end
    local view = PreviewView(doc)
    core.root_view:get_active_node_default():split("right", view)
  end
  -- second name so that typing "markdown" in the command palette finds it
  return { ["mdpreview:toggle"] = toggle, ["markdown:preview-toggle"] = toggle }
end)())

-- Exact rendering (MathJax) in the default browser, using pandoc (needs internet for MathJax).
local function find_pandoc()
  for _, p in ipairs { config.plugins.mdpreview.pandoc, "D:/Programs/LaTeX/pandoc/pandoc.exe" } do
    if p and p ~= "" and system.get_file_info(p) then return p end
  end
  return "pandoc"
end

local function md_doc_active()
  local v = core.active_view
  if v:is(PreviewView) then return true, v.doc end
  if not v:is(DocView) then return false end
  local name = (v.doc.filename or ""):lower()
  return (name:match("%.md$") or name:match("%.markdown$") or name:match("%.mdx$") or name:match("%.mkd$")) ~= nil, v.doc
end

-- pandoc's gfm reader only knows $..$ and $$..$$; rewrite \(..\) and \[..\] outside code fences.
local function convert_math_delims(text)
  local out, chunk, in_fence = {}, {}, false
  local function flush_chunk()
    if #chunk == 0 then return end
    local t = table.concat(chunk, "\n")
    t = t:gsub("\\%[(.-)\\%]", function(m) return "$$" .. m .. "$$" end)
    t = t:gsub("\\%((.-)\\%)", function(m) return "$" .. m .. "$" end)
    out[#out + 1] = t
    chunk = {}
  end
  for line in (text:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      if not in_fence then flush_chunk() end
      in_fence = not in_fence
      out[#out + 1] = line
    elseif in_fence then
      out[#out + 1] = line
    else
      chunk[#chunk + 1] = line
    end
  end
  flush_chunk()
  return table.concat(out, "\n")
end

command.add(md_doc_active, {
  ["markdown:open-in-browser"] = function(doc)
    local tmp = (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/")
    local base = (doc:get_name():match("([^/\\]+)$") or "doc"):gsub("[^%w%.%-_]", "_")
    local md, html, head = tmp .. "/lxl-" .. base .. ".md", tmp .. "/lxl-" .. base .. ".html", tmp .. "/lxl-head.html"
    local f = assert(io.open(md, "wb")); f:write(convert_math_delims(doc:get_text(1, 1, math.huge, math.huge))); f:close()
    local dir = doc.abs_filename and doc.abs_filename:match("^(.*)[/\\][^/\\]*$")
    f = assert(io.open(head, "wb"))
    f:write([[<style>body{max-width:50em;margin:2em auto;padding:0 1em;font-family:sans-serif;line-height:1.5}
table{border-collapse:collapse}td,th{border:1px solid #888;padding:.3em .6em}pre{background:#f4f4f4;padding:.6em;overflow:auto}
header#title-block-header{display:none}</style>]])
    if dir then f:write('<base href="file:///' .. dir:gsub("\\", "/") .. '/">') end
    f:close()
    local ok, proc = pcall(process.start, { find_pandoc(), "-f", "gfm+tex_math_dollars", "-s", "--mathjax",
      "-M", "title=" .. base, "-H", head, "-o", html, md })
    if not ok then core.error("markdown: cannot run pandoc: %s", tostring(proc)) return end
    core.add_thread(function()
      while proc:running() do coroutine.yield(0.05) end
      if proc:returncode() == 0 then open_external(html)
      else core.error("markdown: pandoc failed (code %s)", tostring(proc:returncode())) end
    end)
  end,
})

keymap.add { ["ctrl+shift+m"] = "mdpreview:toggle", ["alt+m"] = "mdpreview:toggle",
             ["ctrl+alt+m"] = "markdown:open-in-browser" }

-- not returned: the workspace plugin would try to restore the view as `require(module)()` without a document
return true
