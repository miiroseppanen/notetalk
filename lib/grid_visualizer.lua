-- Grid Visualizer: VU + pitch visualisointi gridille
-- Eriytetty notetalk.lua:sta. Käyttää statea, paramsia ja source_is_sample()-funktiota.

local GridVisualizer = {}
GridVisualizer.__index = GridVisualizer

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function round(x)
  return math.floor(x + 0.5)
end

local function pitch_to_x(pitch_midi, cols, pitch_min_midi, pitch_max_midi)
  if pitch_midi == nil or cols < 1 then
    return nil
  end
  if cols == 1 then
    return 1
  end
  local min_midi = math.min(pitch_min_midi, pitch_max_midi)
  local max_midi = math.max(pitch_min_midi, pitch_max_midi)
  if max_midi == min_midi then
    return 1
  end
  local clamped = clamp(pitch_midi, min_midi, max_midi)
  local norm = (clamped - min_midi) / (max_midi - min_midi)
  local x = 1 + round(norm * (cols - 1))
  return clamp(x, 1, cols)
end

-- VU-tyylinen mappaus: pienet tasot nostavat palkkia enemmän (log-tyyppinen), isommat eivät ylikäy
-- level 0–1 → display 0–1, power < 1 vahvistaa matalia
local function vu_curve(level, power)
  if level <= 0 then return 0 end
  power = power or 0.55
  return math.pow(clamp(level, 0, 1), power)
end

local function amp_to_lit_rows(amp_norm, vu_floor, rows)
  if rows < 1 then
    return 0
  end
  local floor_value = clamp(vu_floor, 0, 0.99)
  local amp_adj = clamp((clamp(amp_norm or 0, 0, 1) - floor_value) / (1 - floor_value), 0, 1)
  return clamp(round(amp_adj * rows), 0, rows)
end

function GridVisualizer.new(opts)
  local self = setmetatable({}, GridVisualizer)
  self.state = opts.state
  self.params = opts.params
  self.source_is_sample = opts.source_is_sample
  self.option_index = opts.option_index or function(_, _) return 1 end
  self.connect_grid = opts.connect_grid
  self.grid_module = opts.grid_module
  self.g = nil
  self.grid_cols = 0
  self.grid_rows = 0
  self.redraw_metro = nil
  return self
end

function GridVisualizer:add_params()
  local params = self.params
  local state = self.state
  params:add_separator("grid_viz_sep", "Grid Visualizer")
  params:add_control("vu_floor", "VU Floor", controlspec.new(0, 0.5, "lin", 0, 0.08, ""))
  params:add_number("pitch_min_midi", "Pitch Min MIDI", 0, 127, 36)
  params:add_number("pitch_max_midi", "Pitch Max MIDI", 0, 127, 96)
  params:add_option("vu_mode", "VU Mode", {"column", "wide"}, 2)
  params:add_option("line_mode", "Line Mode", {"threshold", "onset"}, 1)
  params:add_option("vu_test_mode", "VU Test Animation", {"off", "on"}, 1)
  params:set_action("vu_test_mode", function(value)
    state.vu_test_mode = (value == 2)
  end)
end

function GridVisualizer:apply_defaults_for_size(cols, rows)
  if cols <= 0 or rows <= 0 then
    return
  end
  local params = self.params
  if cols <= 8 and rows <= 8 then
    params:set("vu_mode", self.option_index({"column", "wide"}, "column"))
    params:set("pitch_min_midi", 48)
    params:set("pitch_max_midi", 84)
  else
    params:set("vu_mode", self.option_index({"column", "wide"}, "wide"))
    params:set("pitch_min_midi", 36)
    params:set("pitch_max_midi", 96)
  end
end

function GridVisualizer:draw()
  local g = self.g
  if not g then return end

  local cols = self.grid_cols or g.cols or 16
  local rows = self.grid_rows or g.rows or 8
  if cols < 1 or rows < 1 then return end

  local state = self.state
  local params = self.params
  local source_is_sample = self.source_is_sample

  local ok, err = pcall(function()
    g:all(0)
    local vu_floor = params:get("vu_floor") or 0.02

    if state.vu_test_mode then
      local t = util.time()
      for x = 1, cols do
        local freq_ratio = (x - 1) / math.max(1, cols - 1)
        local freq = 0.5 + freq_ratio * 3.0
        local phase = t * freq * math.pi * 2
        local amp = 0.3 + (math.sin(phase) * 0.35 + 0.35) * 0.7
        local noise = math.sin(phase * 1.7) * 0.1
        amp = clamp(amp + noise, 0, 1)
        local lit_rows_for_col = math.max(1, round(amp * rows))
        for i = 0, lit_rows_for_col - 1 do
          local y = rows - i
          if y >= 1 and y <= rows then
            local brightness = clamp(4 + round(11 * (i / math.max(1, lit_rows_for_col - 1))), 4, 15)
            g:led(x, y, brightness)
          end
        end
      end
    else
      local sample_mode = source_is_sample()
      local vu_raw
      if sample_mode then
        -- Käytä amp_for_vu (pelkkä volume), ei amp_norm (sis. trigger-pulssin) → ei nousua hiljaisella
        local a = state.amp_for_vu or state.amp_norm or 0
        local v = state.vu_level or 0
        vu_raw = math.max(a, v)
        vu_raw = math.min(1, vu_raw * 1.8)  -- maltillinen vahvistus, ei koko ajan maksimissa
        vu_floor = 0.02
      else
        vu_raw = clamp(state.vu_level or 0, 0, 1)
      end
      -- VU-käyrä: lievä nosto matalille, max vain oikeasti koville piikeille (power > 0.5)
      local vu_amp = vu_curve(vu_raw, 0.68)

      local pitch_min = params:get("pitch_min_midi") or 36
      local pitch_max = params:get("pitch_max_midi") or 96
      local pitch_midi_grid = state.normalized_pitch_midi or state.pitch_midi
      local pitch_x = nil
      if pitch_midi_grid and pitch_midi_grid >= pitch_min and pitch_midi_grid <= pitch_max then
        pitch_x = pitch_to_x(pitch_midi_grid, cols, pitch_min, pitch_max)
      end
      local decay = sample_mode and 0.46 or 0.70   -- nopea putoaminen, erityisesti line-in
      local rise_speed = sample_mode and 1.0 or 0.55  -- nopeampi lasku line-in
      local spread_radius = math.max(2, math.floor(cols * 0.35))
      local spread_inv = 1 / (spread_radius + 1)
      for x = 1, cols do
        state.grid_col_amp[x] = (state.grid_col_amp[x] or 0) * decay
      end
      if vu_amp > 0 then
        if sample_mode then
          -- Sarakkeiden ero: pitch-piikki (keskitysbias ettei vain vasemmalle) + matala pohja
          local center_col = (cols * 0.5) + 0.5
          local peak_center = pitch_x and round(0.35 * pitch_x + 0.65 * center_col) or round(center_col)
          peak_center = clamp(peak_center, 1, cols)
          local base = vu_amp * 0.25  -- pohja kaikille, ei yhtenäinen maksimi
          for x = 1, cols do
            local dist = math.abs(x - peak_center)
            local peak = (dist <= spread_radius) and (vu_amp * (1 - (dist * spread_inv) * 0.7)) or 0
            local target = clamp(base + peak, 0, 1)
            state.grid_col_amp[x] = math.max(target, state.grid_col_amp[x] or 0)
          end
        else
          -- Line-in: pitch-piikki tai koko leveys
          for x = 1, cols do
            local target = 0
            if pitch_x then
              local dist = math.abs(x - pitch_x)
              local peak = (dist <= spread_radius) and (vu_amp * (1 - (dist * spread_inv) * 0.65)) or 0
              target = target + peak
            else
              target = vu_amp
            end
            target = clamp(target, 0, 1)
            state.grid_col_amp[x] = math.max(target, state.grid_col_amp[x] or 0)
          end
        end
      end
      -- Nousu = välitön (target), lasku = tasoitettu → minimaalinen reaktioaika
      for x = 1, cols do
        local target = state.grid_col_amp[x] or 0
        local cur = state.grid_col_display[x] or 0
        if target > cur then
          state.grid_col_display[x] = target
        else
          state.grid_col_display[x] = clamp(cur + (target - cur) * rise_speed, 0, 1)
        end
      end

      local rows_m1 = rows - 1
      for x = 1, cols do
        local col_level = state.grid_col_display[x] or 0
        local lit_rows_x = amp_to_lit_rows(col_level, vu_floor, rows)
        local inv_ht = (lit_rows_x > 1) and (1 / (lit_rows_x - 1)) or 0
        for i = 0, lit_rows_x - 1 do
          local y = rows - i
          if y >= 1 then
            local brightness = (lit_rows_x > 1) and clamp(4 + round(11 * (i * inv_ht)), 4, 15) or 8
            if pitch_x and x == pitch_x then brightness = math.min(15, brightness + 2) end
            g:led(x, y, brightness)
          end
        end
        if lit_rows_x < 1 then g:led(x, rows, 1) end
      end
    end

    g:refresh()
  end)
  if not ok and err then
  end
end

function GridVisualizer:is_ready()
  return self.g ~= nil and self.grid_cols > 0 and self.grid_rows > 0
end

function GridVisualizer:setup()
  if not self.connect_grid then
    return
  end
  self.g = self.connect_grid()
  if not self.g then
    return
  end

  self.grid_cols = self.g.cols or 16
  self.grid_rows = self.g.rows or 8
  if self.grid_cols == 0 or self.grid_rows == 0 then
    self.grid_cols = 16
    self.grid_rows = 8
  end
  if self.g.cols then self.g.cols = self.grid_cols end
  if self.g.rows then self.g.rows = self.grid_rows end

  self:apply_defaults_for_size(self.grid_cols, self.grid_rows)

  self.g.key = function(_, _, _) end
  self:draw()

  if self.redraw_metro then
    pcall(function() self.redraw_metro:stop() end)
    self.redraw_metro = nil
  end
  self.redraw_metro = metro.init()
  if self.redraw_metro then
    self.redraw_metro.time = 1 / 60  -- 60 Hz = minimaalinen viive, synkkaa analyysiin
    self.redraw_metro.event = function()
      pcall(function() self:draw() end)
    end
    self.redraw_metro:start()
  end

  if self.grid_module then
    self.grid_module.add = function()
      self:setup()
    end
  end
end

function GridVisualizer:stop()
  if self.redraw_metro then
    pcall(function() self.redraw_metro:stop() end)
    self.redraw_metro = nil
  end
  self.g = nil
  self.grid_cols = 0
  self.grid_rows = 0
end

return GridVisualizer
