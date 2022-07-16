local M = {}

local Input = require('nui.input')
local event = require('nui.utils.autocmd').event

M.state = {
  last_search = '',
  current_value = ''
}

local utils = require('searchbox.utils')

M.last_search = function()
  return M.state.last_search
end

M.search = function(config, search_opts, handlers)
  local cursor = vim.fn.getcurpos()

  local state = {
    match_ns = utils.hl_namespace,
    winid = vim.fn.win_getid(),
    bufnr = vim.fn.bufnr(),
    line = cursor[2],
    line_prev = -1,
    use_range = false,
    start_cursor = {cursor[2], cursor[3]},
    range = {start = {0, 0}, ends = {0, 0}},
  }

  if search_opts.visual_mode then
    state.range = {
      start = {vim.fn.line("'<"), vim.fn.col("'<")},
      ends = {vim.fn.line("'>"), vim.fn.col("'>")},
    }
  elseif search_opts.range[1] > 0 and search_opts.range[2] > 0 then
    state.use_range = true
    state.range = {
      start = {
        search_opts.range[1],
        1
      },
      ends = {
        search_opts.range[2],
        vim.fn.col({search_opts.range[2], '$'})
      },
    }
  end

  state.search_modifier = utils.get_modifier(search_opts.modifier)

  if state.search_modifier == nil then
    local msg = "[SearchBox] - Invalid value for 'modifier' argument"
    vim.notify(msg:format(search_opts.modifier), vim.log.levels.WARN)
    return
  end

  local title = utils.set_title(search_opts, config)
  local popup_opts = config.popup

  if title ~= '' then
    popup_opts = utils.merge(config.popup, {border = {text = {top = title}}})
  end

  local input = Input(popup_opts, {
    prompt = search_opts.prompt,
    default_value = search_opts.default_value or '',
    on_close = function()
      vim.api.nvim_win_set_cursor(state.winid, state.start_cursor)

      state.on_done = config.hooks.on_done
      handlers.on_close(state)
    end,
    on_submit = function(value)
      M.state.last_search = value
      local query = utils.build_search(value, search_opts, state)
      vim.fn.setreg('/', query)
      vim.fn.histadd('search', query)

      state.on_done = config.hooks.on_done
      handlers.on_submit(value, search_opts, state, popup_opts)
    end,
    on_change = function(value)
      M.state.current_value = value
      handlers.on_change(value, search_opts, state)
    end,
  })

  config.hooks.before_mount(input)

  input:mount()

  input._prompt = search_opts.prompt
  M.default_mappings(input, search_opts, state)

  config.hooks.after_mount(input)

  input:on(event.BufLeave, function()
    handlers.buf_leave(state)
    input:unmount()
  end)
end

M.default_mappings = function(input, search_opts, state)
  local bind = function(modes, lhs, rhs, noremap)
    vim.keymap.set(modes, lhs, rhs, {noremap = noremap, buffer = input.bufnr})
  end

  if vim.fn.has('nvim-0.7') == 0 then
    local prompt = input._prompt
    local prompt_length = 0

    if type(prompt.length) == 'function' then
      prompt_length = prompt:length()
    elseif type(prompt.len) == 'function' then
      prompt_length = prompt:len()
    end

    bind = function(modes, lhs, rhs, noremap)
      for _, mode in ipairs(modes) do
        input:map(mode, lhs, rhs, {noremap = noremap}, true)
      end
    end

    bind('i', '<BS>', function() M.prompt_backspace(prompt_length) end, true)
  end

  local win_exe = function(cmd)
    vim.fn.win_execute(state.winid, string.format('exe "normal! %s"', cmd))
  end

  local move = function(flags)
    vim.api.nvim_buf_call(state.bufnr, function()
      local match = utils.nearest_match(vim.fn.getreg('/'), flags)

      vim.api.nvim_win_set_cursor(state.winid, {match.line, match.col})
      vim.fn.setpos('.', {state.bufnr, match.line, match.col})

      if search_opts._type ~= 'incsearch' then
        return
      end

      vim.api.nvim_buf_clear_namespace(state.bufnr, utils.hl_namespace, 0, -1)
      utils.highlight_text(state.bufnr, utils.hl_name, match)
    end)
  end

  bind({'', 'i'}, '<Plug>(searchbox-close)', input.input_props.on_close, true)

  bind({'', 'i'}, '<Plug>(searchbox-scroll-up)', function() win_exe('\\<C-y>') end, true)
  bind({'', 'i'}, '<Plug>(searchbox-scroll-down)', function() win_exe('\\<C-e>') end, true)

  bind({'', 'i'}, '<Plug>(searchbox-scroll-page-up)', function() win_exe('\\<C-b>') end, true)
  bind({'', 'i'}, '<Plug>(searchbox-scroll-page-down)', function() win_exe('\\<C-f>') end, true)

  bind({'', 'i'}, '<Plug>(searchbox-prev-match)', function() move('bw') end, true)
  bind({'', 'i'}, '<Plug>(searchbox-next-match)', function() move('w') end, true)

  vim.api.nvim_buf_set_keymap(
    input.bufnr,
    'i',
    '<Plug>(searchbox-last-search)',
    "<C-r>=v:lua.require'searchbox.inputs'.last_search()<cr>",
    {noremap = true, silent = true}
  )

  bind({'i'}, '<C-c>', '<Plug>(searchbox-close)', false)
  bind({'i'}, '<Esc>', '<Plug>(searchbox-close)', false)

  bind({'i'}, '<C-y>', '<Plug>(searchbox-scroll-up)', false)
  bind({'i'}, '<C-e>', '<Plug>(searchbox-scroll-down)', false)

  bind({'i'}, '<C-b>', '<Plug>(searchbox-scroll-page-up)', false)
  bind({'i'}, '<C-f>', '<Plug>(searchbox-scroll-page-down)', false)

  bind({'i'}, '<C-g>', '<Plug>(searchbox-prev-match)', false)
  bind({'i'}, '<C-l>', '<Plug>(searchbox-next-match)', false)

  bind({'i'}, '<M-.>', '<Plug>(searchbox-last-search)', false)
end

-- Default backspace has inconsistent behavior, have to make our own (for now)
-- Taken from here:
-- https://github.com/neovim/neovim/issues/14116#issuecomment-976069244
M.prompt_backspace = function(prompt)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1]
  local col = cursor[2]

  if col ~= prompt then
    vim.api.nvim_buf_set_text(0, line - 1, col - 1, line - 1, col, {''})
    vim.api.nvim_win_set_cursor(0, {line, col - 1})
  end
end

return M

