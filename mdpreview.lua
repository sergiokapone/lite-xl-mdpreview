-- mod-version:3
--
-- mdpreview: rendered Markdown preview in a Lite XL tab (Ctrl+Shift+M).
--
-- Headings, bold/italic, `inline code`, fenced code blocks, bullet/numbered
-- lists, block quotes, horizontal rules, simple tables and clickable links.
-- Links open in the browser (http/https) or in the editor / default program
-- (relative files). The preview follows edits live. No external tools needed.
-- Not supported: images (shown as a "[img: alt]" link), math, raw HTML.

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
}, config.plugins.mdpreview)

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
    try("img", "!%[([^%]]*)%]%(([^%)]+)%)")
    try("link", "%[([^%]]+)%]%(([^%)]+)%)")
    try("bold", "%*%*(.-)%*%*")
    try("bold", "__(.-)__")
    try("italic", "%*([^%*%s][^%*]-)%*")
    try("url", "(https?://[^%s<>%)%]]+)")
    if not best then emit(s:sub(pos)) break end
    emit(s:sub(pos, bs - 1))
    if best == "code" then emit(c1, { code = true })
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
  local blocks = parse_blocks(self.doc:get_text(1, 1, math.huge, math.huge))

  -- word-wrapped rich text; returns the new y
  local function flow(spans, x0, xmax, y0, scale, color, force_bold)
    local x, line, lh = x0, {}, 0
    local function flush_line()
      for _, it in ipairs(line) do
        it.y = y0 + (lh - it.h)
        items[#items + 1] = it
      end
      y0, x, line, lh = y0 + lh, x0, {}, 0
    end
    for _, sp in ipairs(spans) do
      local font = self:font(sp.code and "code" or "ui", sp.bold or force_bold, sp.italic, scale)
      local fh = font:get_height()
      local col = sp.link and link_color or color
      local function put(word)
        local w = font:get_width(word)
        if x + w > xmax and x > x0 and not word:match("^%s+$") then
          flush_line()
        end
        if not (x == x0 and word:match("^%s+$")) then
          line[#line + 1] = { text = word, font = font, color = col, x = x, w = w, h = fh, link = sp.link, code = sp.code }
          x = x + w
          lh = math.max(lh, fh)
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

keymap.add { ["ctrl+shift+m"] = "mdpreview:toggle", ["alt+m"] = "mdpreview:toggle" }

-- not returned: the workspace plugin would try to restore the view as `require(module)()` without a document
return true
