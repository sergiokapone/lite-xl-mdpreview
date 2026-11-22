# lite-xl-mdpreview

A [Lite XL](https://lite-xl.com) plugin that shows a **rendered Markdown preview
inside the editor**, in a tab next to the source. No external tools needed.

Press `Ctrl+Shift+M` (or `Alt+M`) in a Markdown document to open the preview;
press it again to close it. The preview follows your edits live.

Supported: headings, **bold**, *italic*, `inline code`, fenced code blocks,
bullet / numbered lists, block quotes, horizontal rules, simple tables and
clickable links (`http(s)` open in the browser, relative `.md` files open in the
editor, other files in the default program). YAML front matter is skipped.

Not supported: images (shown as an `[img: alt]` link), math, raw HTML.

## Install

Copy `mdpreview.lua` into your Lite XL `plugins` folder.

```lua
-- optional, in your user init.lua
config.plugins.mdpreview.max_width = 900 * SCALE  -- text column width (0 = full width)
```

Requires Lite XL 2.1+ (`mod-version:3`). Tested on Lite XL 2.1.8, Windows.

## License

MIT
