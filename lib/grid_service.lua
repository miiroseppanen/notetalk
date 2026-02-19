local grid = require "grid"

local GridService = {}
GridService.__index = GridService

function GridService.new(opts)
  local self = setmetatable({}, GridService)
  self.params = opts.params
  self.get_signal = opts.get_signal
  self.hz_to_midi = opts.hz_to_midi
  self.clamp = opts.clamp
  self.round = opts.round
  self.line_fade_ms = opts.line_fade_ms or 500
  self.grid_recover_ticks = opts.grid_recover_ticks or 120
  self.debug_log = opts.debug_log or function(_, _, _, _) end
  self.debug_should_log = opts.debug_should_log or function(_, _) return false end
  self.g = nil
  self.grid_cols = 0
  self.grid_rows = 0
  self.grid_not_ready_ticks = 0
  self.last_valid_x = nil
  self.onset_x = nil
  self.active_line_y = nil
  self.active_line_t0 = nil
  self.redraw_metro = nil
  return self
end

local function amp_to_lit_rows(amp_norm, floor_norm, rows, clamp)
  local effective = clamp((amp_norm - floor_norm) / math.max(0.0001, 1 - floor_norm), 0, 1)
  return clamp(math.floor(effective * rows + 0.5), 0, rows)
end

local function pitch_to_x(midi_value, cols, pitch_min, pitch_max, clamp)
  local span = math.max(1, pitch_max - pitch_min)
  local normalized = clamp((midi_value - pitch_min) / span, 0, 1)
  return clamp(math.floor(normalized * (cols - 1) + 1.5), 1, cols)
end

local function threshold_to_y(threshold, floor_norm, rows, clamp)
  local effective = clamp((threshold - floor_norm) / math.max(0.0001, 1 - floor_norm), 0, 1)
  local lit = clamp(math.floor(effective * rows + 0.5), 0, rows)
  if lit == 0 then
    return rows
  end
  return clamp(rows - lit + 1, 1, rows)
end

function GridService:is_ready()
  return self.g ~= nil and self.grid_cols > 0 and self.grid_rows > 0
end

function GridService:update_dimensions()
  if self.g then
    self.grid_cols = self.g.cols or 0
    self.grid_rows = self.g.rows or 0
  else
    self.grid_cols = 0
    self.grid_rows = 0
  end
end

function GridService:apply_defaults_for_size()
  local cols = self.grid_cols
  local rows = self.grid_rows
  if cols <= 0 or rows <= 0 then
    return
  end

  if cols <= 8 and rows <= 8 then
    self.params:set("vu_mode", 1)
    self.params:set("pitch_min_midi", 48)
    self.params:set("pitch_max_midi", 84)
  else
    self.params:set("vu_mode", 2)
    self.params:set("pitch_min_midi", 36)
    self.params:set("pitch_max_midi", 96)
  end
end

function GridService:on_analysis_event(event)
  if not self:is_ready() then
    return
  end
  local min_conf = self.params:get("min_conf")
  local conf = self.clamp(event.confidence or 0, 0, 1)
  if conf < min_conf then
    return
  end

  local pitch_midi = self.hz_to_midi(event.hz)
  local pitch_min = self.params:get("pitch_min_midi")
  local pitch_max = self.params:get("pitch_max_midi")
  self.onset_x = pitch_to_x(pitch_midi, self.grid_cols, pitch_min, pitch_max, self.clamp)

  local selected_line_mode = self.params:string("line_mode")
  local y = self.grid_rows
  if selected_line_mode == "onset" then
    local onset_lit = amp_to_lit_rows(event.amp or 0, self.params:get("vu_floor"), self.grid_rows, self.clamp)
    if onset_lit == 0 then
      y = self.grid_rows
    else
      y = self.clamp(self.grid_rows - onset_lit + 1, 1, self.grid_rows)
    end
  else
    y = threshold_to_y(self.params:get("threshold"), self.params:get("vu_floor"), self.grid_rows, self.clamp)
  end
  self.active_line_y = y
  self.active_line_t0 = util.time()
end

function GridService:redraw()
  self:update_dimensions()
  if not self:is_ready() then
    -- Grid spam completely disabled during debugging
    self.grid_not_ready_ticks = self.grid_not_ready_ticks + 1
    -- print("grid not ready: cols=" .. self.grid_cols .. " rows=" .. self.grid_rows)
    local grid_ports = (grid.vports and #grid.vports) or 0
    if self.debug_should_log("grid_not_ready", 2.0) then
      self.debug_log("H1", "lib/grid_service.lua:redraw", "grid_not_ready", {
        cols = self.grid_cols,
        rows = self.grid_rows,
        grid_connected = (self.g ~= nil),
        not_ready_ticks = self.grid_not_ready_ticks,
        grid_ports = grid_ports,
      })
    end
    if self.g ~= nil and (self.grid_not_ready_ticks % self.grid_recover_ticks) == 0 then
      self.g = nil
      self.g = grid.connect(1)
      self:update_dimensions()
      if self:is_ready() then
        self:apply_defaults_for_size()
        self.grid_not_ready_ticks = 0
        self.last_valid_x = nil
        self.onset_x = nil
        self.active_line_y = nil
        self.active_line_t0 = nil
      end
    end
    return
  end
  self.grid_not_ready_ticks = 0
  self.g:all(0)

  local sig = self.get_signal()
  -- Reduce grid signal spam: only log occasionally
  if not self.last_signal_log or util.time() - self.last_signal_log > 3 then
    print("grid signal: amp=" .. (sig.amp_norm or -1) .. " pitch_midi=" .. (sig.pitch_midi or -1))
    self.last_signal_log = util.time()
  end
  local amp_norm = self.clamp(sig.amp_norm or 0, 0, 1)
  local pitch_midi = sig.pitch_midi
  local pitch_conf = self.clamp(sig.pitch_conf or 0, 0, 1)
  local min_conf = sig.min_conf
  local pitch_min = sig.pitch_min
  local pitch_max = sig.pitch_max
  local vu_floor = sig.vu_floor

  local current_x = nil
  if pitch_midi and pitch_conf >= min_conf then
    current_x = pitch_to_x(pitch_midi, self.grid_cols, pitch_min, pitch_max, self.clamp)
    self.last_valid_x = current_x
  elseif self.last_valid_x then
    current_x = self.last_valid_x
  else
    current_x = math.ceil(self.grid_cols / 2)
  end
  current_x = self.clamp(current_x, 1, self.grid_cols)

  local lit = amp_to_lit_rows(amp_norm, vu_floor, self.grid_rows, self.clamp)
  if lit > 0 then
    if sig.vu_mode == "wide" then
      for x = 1, self.grid_cols do
        for i = 0, lit - 1 do
          local y = self.grid_rows - i
          self.g:led(x, y, 3)
        end
      end
    end
    for i = 0, lit - 1 do
      local y = self.grid_rows - i
      self.g:led(current_x, y, 10)
    end
  end

  local heartbeat_on = (math.floor(util.time() * 2) % 2) == 0
  if heartbeat_on then
    self.g:led(1, 1, 2)
  end

  if self.active_line_y and self.active_line_t0 then
    local age_ms = (util.time() - self.active_line_t0) * 1000
    if age_ms < self.line_fade_ms then
      local line_brightness = self.round(15 * (1 - (age_ms / self.line_fade_ms)))
      line_brightness = self.clamp(line_brightness, 0, 15)
      if line_brightness > 0 then
        for x = 1, self.grid_cols do
          self.g:led(x, self.active_line_y, line_brightness)
        end
      end
    else
      self.active_line_y = nil
      self.active_line_t0 = nil
    end
  end
  self.g:refresh()
end

function GridService:setup()
  self.g = grid.connect(1)
  self:update_dimensions()
  self.grid_not_ready_ticks = 0
  if self:is_ready() then
    self:apply_defaults_for_size()
  end
  if self.g then
    self.g.key = function(_, _, _) end
  end

  grid.add = function()
    self.g = grid.connect(1)
    self:update_dimensions()
    self.grid_not_ready_ticks = 0
    if self:is_ready() then
      self:apply_defaults_for_size()
      self.last_valid_x = nil
      self.onset_x = nil
      self.active_line_y = nil
      self.active_line_t0 = nil
    end
  end

  grid.remove = function()
    self:update_dimensions()
    if not self:is_ready() then
      self.g = nil
      self.grid_cols = 0
      self.grid_rows = 0
      self.grid_not_ready_ticks = 0
      self.last_valid_x = nil
      self.onset_x = nil
      self.active_line_y = nil
      self.active_line_t0 = nil
    end
  end

  self.redraw_metro = metro.init()
  self.redraw_metro.time = 1 / 30
  self.redraw_metro.event = function() self:redraw() end
  self.redraw_metro:start()
end

function GridService:stop()
  if self.redraw_metro then
    self.redraw_metro:stop()
    self.redraw_metro = nil
  end
  self.g = nil
  self.grid_cols = 0
  self.grid_rows = 0
  self.grid_not_ready_ticks = 0
  self.last_valid_x = nil
  self.onset_x = nil
  self.active_line_y = nil
  self.active_line_t0 = nil
end

return GridService
