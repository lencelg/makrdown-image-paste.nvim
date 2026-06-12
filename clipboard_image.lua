-- =============================================================================
-- markdown-img-paste.nvim (Single File Edition) – Fully Commented
-- For Neovim 0.12+ built-in package manager | Wayland/X11
-- Requires: wl-clipboard (Wayland) or xclip (X11)
-- =============================================================================
-- This plugin allows you to paste images from your system clipboard directly
-- into a Markdown document. The image is saved into an `img/` directory
-- relative to the current file, and a Markdown image link is inserted.
-- =============================================================================

-- Prevent the plugin from being loaded more than once.
if vim.g.loaded_markdown_img_paste then return end
vim.g.loaded_markdown_img_paste = true

-- Main plugin table (private to this file).
local M = {}

-- =============================================================================
-- CONFIGURATION (user overridable via M.setup())
-- =============================================================================
M.config = {
  -- Relative directory where images will be stored (under the current file).
  img_dir           = "img",

  -- Key mapping to trigger the paste command (set to false to disable).
  keymap            = "<leader>p",

  -- Automatically create a buffer-local keymap for Markdown files?
  create_keymap     = true,

  -- Allow overwriting an existing file? If false, a unique name is generated.
  overwrite         = false,

  -- Where to insert the Markdown reference:
  -- "after_cursor"  → insert on the next line(s) after the cursor.
  -- "current_line"  → append to the end of the current line.
  insert_at         = "after_cursor",

  -- When insert_at is "after_cursor", should we insert an empty line first?
  insert_blank_line = true,

  -- Allow pasting even if the buffer is not yet saved to a file?
  -- If true, images are saved in fallback_dir (or current working directory).
  allow_unsaved     = false,

  -- Fallback directory used when the buffer is unsaved (cwd if nil).
  fallback_dir      = nil,

  -- Custom filename sanitizer function.
  -- Receives (raw_text, is_extension) and should return a cleaned string.
  -- If nil, a built‑in sanitizer is used (keeps alphanumeric, hyphens, underscores).
  sanitizer         = nil,
}

-- =============================================================================
-- PUBLIC SETUP FUNCTION
-- =============================================================================
-- Call this (optionally) in your init.lua to override defaults.
-- Example:
--   require('markdown-img-paste').setup({ keymap = "<leader>i", insert_blank_line = false })
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if M.config.create_keymap and M.config.keymap then
    -- Remove any previously created autocmd to avoid duplicates.
    if M._autocmd_id then
      vim.api.nvim_del_autocmd(M._autocmd_id)
    end
    -- Create a new autocmd that sets a buffer-local keymap for every Markdown buffer.
    M._autocmd_id = vim.api.nvim_create_autocmd("FileType", {
      pattern = "markdown",
      callback = function()
        vim.keymap.set("n", M.config.keymap, "<cmd>PasteMarkdownImg<CR>", {
          buffer = true,
          desc = "Paste image from clipboard",
        })
      end,
    })
  end
end

-- =============================================================================
-- LOW‑LEVEL HELPERS
-- =============================================================================

--- Detect whether we are running under Wayland or X11.
--- @return "wayland"|"x11"
local function detect_display_server()
  if vim.env.WAYLAND_DISPLAY and vim.env.WAYLAND_DISPLAY ~= "" then
    return "wayland"
  end
  if vim.env.XDG_SESSION_TYPE == "wayland" then
    return "wayland"
  end
  return "x11"
end

--- Ask the clipboard tool for a list of available MIME types and return the
--- best image type (e.g. "image/png") or nil if none exists.
--- Preference: png > jpeg > gif > bmp > webp > any other "image/*".
--- @return string|nil
local function get_best_clipboard_type()
  local server = detect_display_server()
  local cmd
  if server == "wayland" then
    cmd = "wl-paste --list-types 2>/dev/null"
  else
    cmd = "xclip -selection clipboard -t TARGETS -o 2>/dev/null"
  end

  local handle = io.popen(cmd)
  if not handle then return nil end
  local list = handle:read("*a")
  handle:close()
  if not list or list == "" then return nil end

  -- Ordered list of preferred image MIME types.
  local preferred = {
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/bmp",
    "image/webp",
  }
  for _, mime in ipairs(preferred) do
    -- plain string search so we don't need to escape special characters.
    if list:find(mime, 1, true) then
      return mime
    end
  end

  -- No preferred type found; fall back to any "image/*" type.
  for mime in list:gmatch("image/%S+") do
    return mime
  end

  return nil
end

--- Map a MIME type to a file extension.
--- @param mime string
--- @return string
local function ext_from_mime(mime)
  local map = {
    ["image/png"]  = "png",
    ["image/jpeg"] = "jpg",
    ["image/gif"]  = "gif",
    ["image/bmp"]  = "bmp",
    ["image/webp"] = "webp",
  }
  return map[mime] or "png"
end

--- Retrieve the image from the system clipboard and save it to a temporary file.
--- The file extension is chosen based on the actual image format.
--- @return table|nil  { path = "/tmp/...", ext = "png" } or nil on failure.
local function get_clipboard_image()
  local mime = get_best_clipboard_type()
  if not mime then return nil end

  local ext = ext_from_mime(mime)
  local server = detect_display_server()
  -- Create a temporary file with the correct extension.
  local tmpfile = vim.fn.tempname() .. "." .. ext

  -- Build shell command. Use shellescape to safely handle special characters.
  local cmd
  if server == "wayland" then
    cmd = string.format(
      "wl-paste --type %s > %s 2>/dev/null",
      vim.fn.shellescape(mime),
      vim.fn.shellescape(tmpfile)
    )
  else
    cmd = string.format(
      "xclip -selection clipboard -t %s -o > %s 2>/dev/null",
      vim.fn.shellescape(mime),
      vim.fn.shellescape(tmpfile)
    )
  end

  local ret = os.execute(cmd)
  if ret ~= 0 then
    os.remove(tmpfile)
    return nil
  end

  -- Double‑check that the file is non‑empty (some tools create empty files).
  local f = io.open(tmpfile, "r")
  if not f then return nil end
  local size = f:seek("end")
  f:close()
  if size == 0 then
    os.remove(tmpfile)
    return nil
  end

  return { path = tmpfile, ext = ext }
end

--- Ensure a directory exists; create it (and parents) if it doesn't.
--- @param path string
local function ensure_dir(path)
  if vim.fn.isdirectory(path) == 0 then
    vim.fn.mkdir(path, "p")
  end
end

--- Determine where to save the image.
--- If the buffer is saved, returns the directory containing the file.
--- Otherwise, respects allow_unsaved and fallback_dir configuration.
--- @return string|nil
local function get_base_dir()
  if vim.bo.filetype ~= "markdown" then return nil end

  local file_dir = vim.fn.expand("%:p:h")
  if file_dir ~= "" then return file_dir end

  if M.config.allow_unsaved then
    return M.config.fallback_dir or vim.fn.getcwd()
  end

  vim.notify(
    "Please save the Markdown file first (or set `allow_unsaved = true`)",
    vim.log.levels.WARN
  )
  return nil
end

--- Default filename sanitizer.
--- For a normal part: replaces non‑alphanumeric characters (except '-' and '_') with '-'.
--- For an extension: keeps only letters and digits, lowercased.
--- @param text string
--- @param is_ext boolean
--- @return string
local function default_sanitizer(text, is_ext)
  if is_ext then
    text = text:gsub("[^%a%d]", ""):lower()
  else
    text = text:gsub("[^%w%-_]", "-")
  end
  return text
end

--- Sanitize a string using the configured sanitizer or the built‑in one.
--- @param text string
--- @param is_ext boolean
--- @return string
local function sanitize(text, is_ext)
  if M.config.sanitizer then
    return M.config.sanitizer(text, is_ext) or text
  end
  return default_sanitizer(text, is_ext)
end

--- Generate a unique filename by appending a number when a conflict is detected.
--- @param base string
--- @param ext string
--- @param dir string
--- @return string
local function unique_filename(base, ext, dir)
  local name = base .. "." .. ext
  local counter = 1
  while vim.fn.filereadable(dir .. "/" .. name) == 1 do
    name = base .. "_" .. counter .. "." .. ext
    counter = counter + 1
    if counter > 100 then
      error("Could not generate a unique filename – too many conflicts.")
    end
  end
  return name
end

--- Move (or copy) a file from src to dst.
--- Tries rename first; if that fails (e.g. cross‑device), reads and writes manually.
--- @param src string
--- @param dst string
--- @return boolean
local function move_or_copy(src, dst)
  local ok = os.rename(src, dst)
  if ok then return true end

  -- Fallback: manual copy
  local r = io.open(src, "rb")
  if not r then return false end
  local w = io.open(dst, "wb")
  if not w then
    r:close()
    return false
  end

  local data = r:read("*a")
  w:write(data)
  r:close()
  w:close()
  os.remove(src)   -- remove the temporary file
  return true
end

--- Split user input into base name and extension.
--- Looks for the *last* dot. If none, the whole input is the base and we use the default extension.
--- @param input string
--- @param default_ext string
--- @return string|nil base, string|nil  ext (both nil on failure)
local function parse_input(input, default_ext)
  -- Trim whitespace
  local trimmed = input:match("^%s*(.-)%s*$")
  if not trimmed or trimmed == "" then
    return nil, nil
  end
  -- Split on the last dot
  local base, ext = trimmed:match("^(.-)%.([^%.]+)$")
  if not base then
    return trimmed, default_ext
  end
  -- If extension is empty (input ended with a dot), use the default
  if #ext == 0 then
    return base, default_ext
  end
  return base, ext
end

--- Insert the Markdown image reference at the current cursor position.
--- Respects insert_at and insert_blank_line configuration.
--- @param base string  The sanitized base filename (used for alt text).
--- @param rel_path string  Relative path to the image (e.g. "img/photo.png").
local function insert_reference(base, rel_path)
  local md_text = string.format("![%s](%s)", base, rel_path)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1  -- 0‑based line index

  if M.config.insert_at == "current_line" then
    -- Append to the current line
    local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1]
    vim.api.nvim_buf_set_lines(0, row, row + 1, false, { line .. md_text })
    vim.api.nvim_win_set_cursor(0, { row + 1, #line + #md_text })
  else
    -- Insert on a new line below
    if M.config.insert_blank_line then
      vim.api.nvim_buf_set_lines(0, row + 1, row + 1, false, { "", md_text })
      vim.api.nvim_win_set_cursor(0, { row + 2, #md_text })
    else
      vim.api.nvim_buf_set_lines(0, row + 1, row + 1, false, { md_text })
      vim.api.nvim_win_set_cursor(0, { row + 1, #md_text })
    end
  end
end

-- =============================================================================
-- PUBLIC COMMAND HANDLERS
-- =============================================================================

--- Paste an image with an interactive filename prompt.
function M.paste_image()
  if vim.bo.filetype ~= "markdown" then
    vim.notify("This command only works in Markdown files.", vim.log.levels.WARN)
    return
  end

  local base_dir = get_base_dir()
  if not base_dir then return end

  -- Get image from clipboard (actual format, saved to temp file)
  local img_info = get_clipboard_image()
  if not img_info then
    vim.notify(
      "No image in clipboard or missing tools (wl-clipboard / xclip)",
      vim.log.levels.WARN
    )
    return
  end

  local img_dir = base_dir .. "/" .. M.config.img_dir
  ensure_dir(img_dir)

  -- The default extension matches the actual clipboard content.
  local default_ext = img_info.ext
  vim.ui.input({
    prompt = "Image filename (e.g. photo or photo.jpg, default: ." .. default_ext .. "): ",
    default = "",
  }, function(input)
    if not input or input == "" then
      os.remove(img_info.path)
      vim.notify("Image paste cancelled.", vim.log.levels.INFO)
      return
    end

    -- Parse the user's input into raw base and extension
    local raw_base, raw_ext = parse_input(input, default_ext)
    if not raw_base then
      os.remove(img_info.path)
      vim.notify("Invalid filename.", vim.log.levels.ERROR)
      return
    end

    -- Sanitize both parts according to the configuration
    local final_base = sanitize(raw_base, false)
    if final_base == "" then final_base = "image" end
    local final_ext = sanitize(raw_ext, true)
    if final_ext == "" then final_ext = default_ext end

    -- Build final filename, respecting the overwrite setting
    local filename = M.config.overwrite
      and (final_base .. "." .. final_ext)
      or unique_filename(final_base, final_ext, img_dir)

    local dest_path = img_dir .. "/" .. filename
    if not move_or_copy(img_info.path, dest_path) then
      os.remove(img_info.path)
      vim.notify("Failed to write " .. dest_path, vim.log.levels.ERROR)
      return
    end

    -- Insert the relative Markdown link
    local rel_path = M.config.img_dir .. "/" .. filename
    insert_reference(final_base, rel_path)

    vim.notify("Image saved as " .. dest_path, vim.log.levels.INFO)
  end)
end

--- Quick paste without a prompt – auto‑generates a timestamp‑based filename.
function M.paste_image_quick()
  if vim.bo.filetype ~= "markdown" then
    vim.notify("This command only works in Markdown files.", vim.log.levels.WARN)
    return
  end

  local base_dir = get_base_dir()
  if not base_dir then return end

  local img_info = get_clipboard_image()
  if not img_info then
    vim.notify(
      "No image in clipboard or missing tools (wl-clipboard / xclip)",
      vim.log.levels.WARN
    )
    return
  end

  local img_dir = base_dir .. "/" .. M.config.img_dir
  ensure_dir(img_dir)

  -- Build a filename from the current date and time
  local base = "img_" .. os.date("%Y%m%d_%H%M%S")
  local ext = img_info.ext
  local filename = M.config.overwrite
    and (base .. "." .. ext)
    or unique_filename(base, ext, img_dir)

  local dest_path = img_dir .. "/" .. filename
  if not move_or_copy(img_info.path, dest_path) then
    os.remove(img_info.path)
    vim.notify("Failed to write " .. dest_path, vim.log.levels.ERROR)
    return
  end

  local rel_path = M.config.img_dir .. "/" .. filename
  insert_reference(base, rel_path)

  vim.notify("  Image saved as " .. dest_path, vim.log.levels.INFO)
end

-- =============================================================================
-- REGISTER USER COMMANDS
-- =============================================================================
vim.api.nvim_create_user_command("PasteMarkdownImg", M.paste_image, {})
vim.api.nvim_create_user_command("PasteMarkdownImgQuick", M.paste_image_quick, {})

-- =============================================================================
-- AUTO‑SETUP WITH DEFAULT CONFIGURATION
-- =============================================================================
-- This ensures that even without a user call to setup() the default keymap works.
M.setup()
