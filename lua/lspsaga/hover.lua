local api, fn, lsp = vim.api, vim.fn, vim.lsp
local config = require('lspsaga').config
local win = require('lspsaga.window')
local util = require('lspsaga.util')
local treesitter = vim.treesitter
local islist = util.is_ten and vim.islist or vim.tbl_islist
local hover = {}

function hover:clean()
  -- print("--- ENTERING hover:clean ---")
  if self.cancel then
    self.cancel()
    self.cancel = nil
  end

  self.bufnr = nil
  self.winid = nil
end

function hover:open_link()
  if not self.bufnr or not api.nvim_buf_is_valid(self.bufnr) then
    return
  end

  local node = treesitter.get_node()
  if not node or node:type() ~= 'inline' then
    return
  end
  local text = treesitter.get_node_text(node, self.bufnr)
  local link = text:match('%]%((.-)%)')

  if not link then
    return
  end

  local cmd

  if vim.fn.has('mac') == 1 then
    cmd = '!open'
  elseif vim.fn.has('win32') == 1 then
    cmd = '!explorer'
  elseif vim.fn.executable('wslview') == 1 then
    cmd = '!wslview'
  elseif vim.fn.executable('xdg-open') == 1 then
    cmd = '!xdg-open'
  else
    cmd = config.hover.open_browser
  end

  if link:find('file://') then
    vim.cmd.edit(vim.uri_to_fname(link))
  else
    fn.execute(cmd .. ' ' .. fn.escape(link, '#'))
  end
end

function hover:open_floating_preview(content, option_fn)
  -- Агрессивная очистка состояния предыдущего ховера
  if self.winid and api.nvim_win_is_valid(self.winid) then
    pcall(api.nvim_win_close, self.winid, true)
  end
  if self.bufnr and api.nvim_buf_is_valid(self.bufnr) then
    pcall(api.nvim_buf_delete, self.bufnr, { force = true })
  end
  self.winid = nil
  self.bufnr = nil
  if self.cancel then
    self.cancel()
    self.cancel = nil
  end

  -- 1. Готовим content_for_calc (основной текст ховера без нашего блока "Links:")
  local content_for_calc = {}
  local in_main_content_for_calc_loop = true
  for i, line in ipairs(content) do
    if in_main_content_for_calc_loop then
      local is_our_separator_start = false
      if string.match(line, '^%s*---%s*$') then
        if content[i + 1] and string.match(content[i + 1], '^%s*Links:%s*$') then
          is_our_separator_start = true
        end
      end
      if is_our_separator_start then
        in_main_content_for_calc_loop = false
      else
        table.insert(content_for_calc, line)
      end
    end
  end

  -- 2. Расчет Идеальной Ширины
  local conf_max_width_factor = config.hover.max_width or 0.8
  local max_allowed_width_config = math.floor(vim.o.columns * conf_max_width_factor)
  local lines_for_width_calc_filter = vim.tbl_filter(function(line_text)
    return not string.match(line_text, '^%s*```') and not string.match(line_text, '^%s*$')
  end, content_for_calc)
  local ideal_width = 0
  if #lines_for_width_calc_filter > 0 then
    for _, line_to_measure in ipairs(lines_for_width_calc_filter) do
      local current_line_contribution = vim.fn.strdisplaywidth(line_to_measure or '')
      if current_line_contribution > 0 then
        if current_line_contribution < max_allowed_width_config then
          if current_line_contribution > ideal_width then
            ideal_width = current_line_contribution
          end
        elseif ideal_width == 0 then
          ideal_width = max_allowed_width_config
        end
      end
    end
    if ideal_width == 0 then
      ideal_width = math.floor(max_allowed_width_config * 0.75)
    end
  else
    ideal_width = math.floor(max_allowed_width_config * 0.5)
  end
  if ideal_width <= 0 then
    ideal_width = 10
  end

  -- 3. ЭТАП 1 ВЫСОТЫ: Получаем "семантически видимые" строки
  -- Важно: здесь мы все еще фильтруем ```, чтобы ПРАВИЛЬНО РАССЧИТАТЬ ВЫСОТУ.
  -- Но для финального отображения мы их оставим.
  local semantically_visible_lines = {}
  local last_added_line_was_empty = false
  for i, line in ipairs(content_for_calc) do
    local skip_processing = false
    if string.match(line, '^%s*```') then
      skip_processing = true
    else
      local is_empty_line = string.match(line, '^%s*$')
      if is_empty_line then
        local prev_is_fence = (
          content_for_calc[i - 1] and string.match(content_for_calc[i - 1], '^%s*```')
        )
        local next_is_fence = (
          content_for_calc[i + 1] and string.match(content_for_calc[i + 1], '^%s*```')
        )
        if prev_is_fence and next_is_fence then
          skip_processing = true
        elseif last_added_line_was_empty then
          skip_processing = true
        end
      end
    end
    if not skip_processing then
      table.insert(semantically_visible_lines, line)
      last_added_line_was_empty = string.match(line, '^%s*$')
    end
  end
  while
    #semantically_visible_lines > 0
    and string.match(semantically_visible_lines[#semantically_visible_lines], '^%s*$')
  do
    table.remove(semantically_visible_lines)
  end

  -- 4. ЭТАП 2 ВЫСОТЫ: "Предварительный рендеринг" для `semantically_visible_lines`
  local ideal_height_from_prerender = 0
  local scratch_bufnr_prerender = nil
  local temp_winid_prerender = nil
  local pr_success, pr_result_or_err = pcall(function()
    if #semantically_visible_lines == 0 then
      ideal_height_from_prerender = 0
      return
    end
    scratch_bufnr_prerender = api.nvim_create_buf(false, true)
    if not scratch_bufnr_prerender or not api.nvim_buf_is_valid(scratch_bufnr_prerender) then
      error('Pre-render: Failed to create scratch buffer')
    end
    api.nvim_buf_set_option(scratch_bufnr_prerender, 'filetype', 'markdown')
    api.nvim_buf_set_option(scratch_bufnr_prerender, 'wrap', true)
    api.nvim_buf_set_option(scratch_bufnr_prerender, 'modifiable', true)
    api.nvim_buf_set_lines(scratch_bufnr_prerender, 0, -1, false, semantically_visible_lines)
    api.nvim_buf_set_option(scratch_bufnr_prerender, 'modifiable', false)
    local temp_win_opts_prerender = {
      relative = 'editor',
      width = ideal_width,
      height = vim.o.lines,
      row = vim.o.lines + 10,
      col = vim.o.columns + 10,
      focusable = false,
      style = 'minimal',
      noautocmd = true,
    }
    temp_winid_prerender =
      api.nvim_open_win(scratch_bufnr_prerender, false, temp_win_opts_prerender)
    if not temp_winid_prerender or not api.nvim_win_is_valid(temp_winid_prerender) then
      error('Pre-render: Failed to create temporary window')
    end
    local line_count_in_prerender_buf = api.nvim_buf_line_count(scratch_bufnr_prerender)
    if line_count_in_prerender_buf == 0 then
      ideal_height_from_prerender = 0
    else
      api.nvim_win_set_cursor(temp_winid_prerender, { line_count_in_prerender_buf, 0 })
      ideal_height_from_prerender = api.nvim_win_get_cursor(temp_winid_prerender)[1]
    end
  end)
  if temp_winid_prerender and api.nvim_win_is_valid(temp_winid_prerender) then
    api.nvim_win_close(temp_winid_prerender, true)
  end
  if scratch_bufnr_prerender and api.nvim_buf_is_valid(scratch_bufnr_prerender) then
    api.nvim_buf_delete(scratch_bufnr_prerender, { force = true })
  end
  if not pr_success then
    print('Error during pre-render height calculation:', pr_result_or_err)
    ideal_height_from_prerender = #semantically_visible_lines
  end

  -- 5. Финальная высота
  local ideal_height = ideal_height_from_prerender
  local final_height_adjustment = 0 -- Оставляем для тонкой подстройки, если понадобится
  ideal_height = ideal_height + final_height_adjustment
  if ideal_height <= 0 then
    if #content_for_calc > 0 then
      ideal_height = 1
    else
      return
    end
  end

  -- --- Финальные опции окна ---
  local conf_max_height_factor = config.hover.max_height or 0.6
  local max_height_from_config = math.floor(vim.o.lines * conf_max_height_factor)
  local float_option = {
    width = math.min(max_allowed_width_config, ideal_width),
    height = math.min(max_height_from_config, ideal_height),
    zindex = 80,
  }

  local new = {}

  local in_codeblock = false

  for _, line in ipairs(content) do
    if line:find('\\') then
      line = line:gsub('\\(?![tn])', '')
    end
    if line:find('%[%w+%][^%(]') and not in_codeblock then
      line = line:gsub('%[', '%[%[')
      line = line:gsub('%]', '%]%]')
    end
    if line:find('\r') then
      line = line:gsub('\r\n?', ' ')
    end
    if line:find('&nbsp;') then
      line = line:gsub('&nbsp;', ' ')
    end
    if line:find('&lt;') then
      line = line:gsub('&lt;', '<')
    end
    if line:find('&gt;') then
      line = line:gsub('&gt;', '>')
    end
    if line:find('<pre>') then
      line = line:gsub('<pre>', '```')
      in_codeblock = true
    end
    if line:find('</pre>') then
      line = line:gsub('</pre>', '```')
      in_codeblock = false
    end
    if line:find('```') then
      in_codeblock = in_codeblock and false or true
    end
    if line:find('^%-%-%-$') then
      line = util.gen_truncate_line(float_option.width)
    end
    if line:find('\\') then
      line = line:gsub('\\', '')
    end
    if #line > 0 then
      new[#new + 1] = line
    end
  end

  local tuncate_lnum = -1
  for i, line in ipairs(new) do
    if line:find('^─') then
      tuncate_lnum = i
    end
  end


  if option_fn then
    float_option = vim.tbl_extend('keep', float_option, option_fn(float_option.width))
  end

  local curbuf = api.nvim_get_current_buf()

  self.bufnr, self.winid = win
    :new_float(float_option, false, option_fn and true or false)
    :setlines(new)
    :bufopt({
      ['filetype'] = 'markdown',
      ['modifiable'] = false,
      ['buftype'] = 'nofile',
      ['bufhidden'] = 'wipe',
    })
    :winopt({
      ['conceallevel'] = 2,
      ['concealcursor'] = 'niv',
      ['showbreak'] = 'NONE',
      ['wrap'] = true,
    })
    :winhl('HoverNormal', 'HoverBorder')
    :wininfo()

  if tuncate_lnum > 0 then
    api.nvim_buf_add_highlight(self.bufnr, 0, 'Type', tuncate_lnum - 1, 0, -1)
  end

  vim.treesitter.start(self.bufnr, 'markdown')
  vim.treesitter.query.set(
    'markdown',
    'highlights',
    [[
      ([
        (info_string)
        (fenced_code_block_delimiter)
      ] @conceal
      (#set! conceal ""))
    ]]
  )

  util.scroll_in_float(curbuf, self.winid)
  api.nvim_create_autocmd('WinClosed', {
    buffer = self.bufnr,
    callback = function()
      util.delete_scroll_map(curbuf)
    end,
  })

  util.map_keys(self.bufnr, 'q', function()
    if self.winid and api.nvim_win_is_valid(self.winid) then
      api.nvim_win_close(self.winid, true)
      self:clean()
    end
  end)

  if not option_fn then
    api.nvim_create_autocmd({ 'CursorMoved', 'InsertEnter', 'BufDelete' }, {
      buffer = curbuf,
      once = true,
      callback = function(opt)
        if self.bufnr and api.nvim_buf_is_loaded(self.bufnr) then
          util.delete_scroll_map(curbuf)
        end

        if self.winid and api.nvim_win_is_valid(self.winid) then
          api.nvim_win_close(self.winid, true)
        end
        self:clean()
        api.nvim_del_autocmd(opt.id)
      end,
      desc = '[Lspsaga] Auto close hover window',
    })

    api.nvim_create_autocmd('BufEnter', {
      callback = function(opt)
        if opt.buf ~= self.bufnr and self.winid and api.nvim_win_is_valid(self.winid) then
          api.nvim_win_close(self.winid, true)
          pcall(api.nvim_del_autocmd, opt.id)
          self:clean()
        end
      end,
    })
  end

  util.map_keys(self.bufnr, config.hover.open_link, function()
    self:open_link()
  end)

  api.nvim_create_autocmd('BufWipeout', {
    buffer = self.bufnr,
    callback = function()
      pcall(util.delete_scroll_map, curbuf)
    end,
  })
end

local function ignore_error(args, can_through)
  if vim.tbl_contains(args, '++silent') and can_through then
    return true
  end
end

function hover:do_request(args)
  -- print("--- ENTERING do_request ---")
  -- print("self.bufnr at start of do_request:", vim.inspect(self.bufnr))
  local method = 'textDocument/hover'
  local clients = util.get_client_by_method(method)
  if #clients == 0 then
    vim.notify('[lspsaga] hover is not supported by the servers of the current buffer')
    return
  end
  local count = 0

  local params = lsp.util.make_position_params(0, util.get_offset_encoding({ client = clients[1] }))
  _, self.cancel = lsp.buf_request(0, method, params, function(_, result, ctx, _)
    -- print("--- LSP Callback Entered ---")
    count = count + 1

    if api.nvim_get_current_buf() ~= ctx.bufnr then
      return
    end

    if not result or not result.contents then
      if not ignore_error(args, count == #clients) then
        vim.notify('No information available')
      end
      return
    end

    -- MarkedString | MarkedString[] | MarkupContent;
    -- type MarkedString = string | { language: string; value: string };
    -- interface MarkupContent { kind: MarkupKind; value: string; }
    local value
    if type(result.contents) == 'string' then -- MarkedString
      value = result.contents
    elseif result.contents.language then -- MarkedString
      if result.contents.language == 'css' then -- tailwindcss
        value = '```css\n' .. result.contents.value .. '\n```'
      else
        value = result.contents.value
      end
    elseif islist(result.contents) then -- MarkedString[]
      if vim.tbl_isempty(result.contents) and ignore_error(args) then
        vim.notify('No information available')
        return
      end
      local values = {}
      for _, ms in ipairs(result.contents) do
        ---@diagnostic disable-next-line: undefined-field
        table.insert(values, type(ms) == 'string' and ms or ms.value)
      end
      value = table.concat(values, '\n')
    elseif result.contents.kind then -- MarkupContent
      value = result.contents.value
    end

    if not value or #value == 0 then
      if ignore_error(args, count == #clients) then
        vim.notify('No information available')
      end
      return
    end
    local content = vim.split(value, '\n', { trimempty = true })
    -- print('--- LSPSAGA RAW CONTENT ---')
    -- print(vim.inspect(content))
    local client = vim.lsp.get_client_by_id(ctx.client_id)
    if not client then
      return
    end
    if #clients ~= 1 then
      content[#content + 1] = '`From: ' .. client.name .. '`'
    end

    if
      self.bufnr
      and api.nvim_buf_is_valid(self.bufnr)
      and self.winid
      and api.nvim_win_is_valid(self.winid)
    then
      -- print("--- TAKING UPDATE PATH in do_request ---")
      vim.bo[self.bufnr].modifiable = true
      local win_conf = api.nvim_win_get_config(self.winid)
      local max_len = util.get_max_content_length(content)
      if max_len > win_conf.width then
        win_conf.width = max_len
      end

      local truncate = util.gen_truncate_line(win_conf.width)
      content = vim.list_extend({ truncate }, content)
      api.nvim_buf_set_lines(self.bufnr, -1, -1, false, content)
      vim.bo[self.bufnr].modifiable = false
      win_conf.height = win_conf.height + #content + 1
      api.nvim_win_set_config(self.winid, win_conf)
      return
    end

    local option_fn
    if vim.tbl_contains(args, '++keep') then
      option_fn = function(width)
        local opt = {}
        opt.relative = 'editor'
        opt.row = 1
        opt.col = vim.o.columns - width - 3
        return opt
      end
    end

    if not self.winid then
      self:open_floating_preview(content, option_fn)
      return
    end
  end)
end

function hover:render_hover_doc(args)
  args = args or {}
  util.valid_markdown_parser()
  if self.winid and api.nvim_win_is_valid(self.winid) then
    if not vim.tbl_contains(args, '++keep') then
      api.nvim_set_current_win(self.winid)
      return
    else
      api.nvim_win_close(self.winid, true)
      self:clean()
      return
    end
  end

  self:clean()
  self:do_request(args)
end

return hover
