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
  local ready = self.g ~= nil and self.grid_cols > 0 and self.grid_rows > 0
  -- Debug occasionally
  if not ready and not self.ready_debug_shown then
    print("grid_service:is_ready() = false: g=" .. tostring(self.g ~= nil) .. 
          " cols=" .. tostring(self.grid_cols) .. " rows=" .. tostring(self.grid_rows))
    self.ready_debug_shown = true
  elseif ready and not self.ready_confirmed then
    print("grid_service:is_ready() = true: " .. self.grid_cols .. "x" .. self.grid_rows)
    self.ready_confirmed = true
  end
  return ready
end

function GridService:update_dimensions()
  if self.g then
    -- For midigrid, assume standard dimensions if missing
    if not self.g.cols or self.g.cols == 0 then
      self.g.cols = 16  -- Standard midigrid width
      self.g.rows = 8   -- Standard midigrid height
      print("grid_service: forced midigrid dimensions in update")
    end
    self.grid_cols = self.g.cols
    self.grid_rows = self.g.rows
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
  -- Skip complex grid checks - just assume midigrid works
  if not self.g then
    if (self.grid_not_ready_ticks % 60) == 0 then
      print("grid_service: no grid, attempting connection...")
      self.g = grid.connect(1)
      if self.g then
        -- Force midigrid dimensions
        self.g.cols = self.g.cols or 16
        self.g.rows = self.g.rows or 8
        self.grid_cols = self.g.cols
        self.grid_rows = self.g.rows
        print("grid_service: reconnected - " .. self.grid_cols .. "x" .. self.grid_rows)
      end
    end
    self.grid_not_ready_ticks = self.grid_not_ready_ticks + 1
    return
  end
  
  -- Force midigrid dimensions if missing
  if not self.grid_cols or self.grid_cols == 0 then
    self.grid_cols = self.g.cols or 16
    self.grid_rows = self.g.rows or 8
    self.g.cols = self.grid_cols
    self.g.rows = self.grid_rows
    print("grid_service: forced midigrid dimensions " .. self.grid_cols .. "x" .. self.grid_rows)
  end
  
  self.grid_not_ready_ticks = 0
  
  -- Confirm we're in redraw at least once
  if not self.redraw_confirmed then
    print("grid_service: redraw active with " .. self.grid_cols .. "x" .. self.grid_rows .. " grid")
    self.redraw_confirmed = true
  end
  
  self.g:all(0)

  local sig = self.get_signal()
  
  -- Enhanced signal validation and debugging
  local amp_norm = self.clamp(sig.amp_norm or 0, 0, 1)
  local pitch_midi = sig.pitch_midi
  local pitch_conf = self.clamp(sig.pitch_conf or 0, 0, 1)
  local min_conf = sig.min_conf or 0.45
  local pitch_min = sig.pitch_min or 36
  local pitch_max = sig.pitch_max or 96
  local vu_floor = sig.vu_floor or 0.08
  
  -- Signal health check and enhanced logging  
  local signal_ok = amp_norm > 0 or (sig.polls_active == true)
  local lit = amp_to_lit_rows(amp_norm, vu_floor, self.grid_rows, self.clamp)
  
  if not self.last_signal_log or util.time() - self.last_signal_log > 1 then
    local log_msg = string.format("GRID: amp=%.4f lit=%d/%d pitch=%s polls=%s mode=%s", 
      amp_norm, 
      lit,
      self.grid_rows,
      pitch_midi and string.format("%.1f", pitch_midi) or "nil",
      tostring(sig.polls_active or false),
      sig.sample_mode and "sample" or "line"
    )
    print(log_msg)
    
    if not signal_ok and self.debug_should_log("grid_signal_health", 4.0) then
      self.debug_log("H16", "lib/grid_service.lua:redraw", "signal_health_warning", {
        amp_norm = amp_norm,
        pitch_midi = pitch_midi or -1,
        pitch_conf = pitch_conf,
        polls_active = sig.polls_active or false,
        sample_mode = sig.sample_mode or false
      })
    end
    
    self.last_signal_log = util.time()
  end

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
  
  -- Debug current_x calculation
  if not self.x_debug_shown then
    print(string.format("grid_service: current_x=%d (from pitch_midi=%s conf=%.2f min_conf=%.2f cols=%d)", 
      current_x, 
      pitch_midi and string.format("%.1f", pitch_midi) or "nil",
      pitch_conf, min_conf, self.grid_cols))
    self.x_debug_shown = true
  end

  local lit = amp_to_lit_rows(amp_norm, vu_floor, self.grid_rows, self.clamp)
  
  -- Enhanced VU display with better visibility for low signals
  -- TEMP DEBUG: Force some VU display for testing
  local force_test_vu = false  -- Set to true to force VU display for testing
  if force_test_vu then
    lit = math.max(lit, 3)  -- Force at least 3 rows for testing
    amp_norm = math.max(amp_norm, 0.3)  -- Force some amplitude for testing
  end
  
  if lit > 0 or amp_norm > 0.001 then  -- Show even very small signals
    lit = math.max(1, lit)  -- Always show at least one row if there's any signal
    
    -- Debug VU calculation
    if not self.vu_debug_shown then
      print(string.format("grid_service: VU display - lit=%d amp_norm=%.4f floor=%.3f rows=%d", 
        lit, amp_norm, vu_floor, self.grid_rows))
      self.vu_debug_shown = true
    end
    
    if sig.vu_mode == "wide" then
      for x = 1, self.grid_cols do
        for i = 0, lit - 1 do
          local y = self.grid_rows - i
          -- Use variable brightness based on signal strength
          local brightness = math.max(2, math.min(6, math.floor(amp_norm * 8) + 1))
          self.g:led(x, y, brightness)
        end
      end
    end
    
    -- Main column with higher brightness
    for i = 0, lit - 1 do
      local y = self.grid_rows - i
      local brightness = math.max(8, math.min(15, math.floor(amp_norm * 15) + 8))
      self.g:led(current_x, y, brightness)
    end
    
    -- Debug LED setting
    if not self.led_debug_shown then
      print(string.format("grid_service: setting LEDs at x=%d, y range %d-%d, brightness %d-%d", 
        current_x, self.grid_rows - lit + 1, self.grid_rows, 
        math.max(8, math.min(15, math.floor(amp_norm * 15) + 8)),
        math.max(8, math.min(15, math.floor(amp_norm * 15) + 8))))
      self.led_debug_shown = true
    end
  end

  local heartbeat_on = (math.floor(util.time() * 2) % 2) == 0
  if heartbeat_on then
    self.g:led(1, 1, 2)
  end
  
  -- Debug heartbeat status occasionally
  if not self.heartbeat_confirmed and heartbeat_on then
    print("grid_service: heartbeat LED set at (1,1)")
    self.heartbeat_confirmed = true
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
  print("grid_service: SAFE midigrid setup...")
  
  -- Single, safe connection attempt
  self.g = grid.connect(1)
  
  if self.g then
    print("grid_service: connected - " .. tostring(self.g))
    
    -- Force midigrid dimensions immediately
    self.g.cols = self.g.cols or 16
    self.g.rows = self.g.rows or 8
    
    -- If still zero, force standard midigrid
    if self.g.cols == 0 then self.g.cols = 16 end
    if self.g.rows == 0 then self.g.rows = 8 end
    
    print("grid_service: dimensions set to " .. self.g.cols .. "x" .. self.g.rows)
  else
    print("grid_service: connection failed")
  end
  
  -- Update our internal state
  self:update_dimensions()
  self.grid_not_ready_ticks = 0
  
  if self.g then
    self.g.key = function(_, _, _) end
    print("grid_service: key handler set")
    
    -- Safe LED test
    print("grid_service: safe LED test...")
    pcall(function()
      self.g:all(0)
      self.g:led(1, 1, 8)    -- Dim test
      self.g:led(self.grid_cols, self.grid_rows, 8)
      self.g:refresh()
    end)
  end
  
  -- Setup redraw metro (SAFE VERSION)
  if self.redraw_metro then
    self.redraw_metro:stop()
    self.redraw_metro = nil
  end
  
  self.redraw_metro = metro.init()
  self.redraw_metro.time = 1 / 20  -- Slower for safety
  self.redraw_metro.event = function() 
    pcall(function() self:redraw() end)  -- Safe redraw
  end
  self.redraw_metro:start()
  print("grid_service: safe redraw metro started")
  
  if self:is_ready() then
    print("grid_service: READY - " .. self.grid_cols .. "x" .. self.grid_rows)
    self:apply_defaults_for_size()
  else
    print("grid_service: not ready, but will try in redraw")
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
  print("grid_service: redraw metro started at 30fps")
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

function GridService:test_basic_display()
  if not self:is_ready() then
    print("grid_service: test failed - grid not ready")
    return false
  end
  
  print("grid_service: running basic grid test...")
  self.g:all(0)
  
  -- Test pattern: corners and center
  local test_positions = {
    {1, 1, 15},  -- top-left bright
    {self.grid_cols, 1, 10},  -- top-right medium
    {1, self.grid_rows, 10},  -- bottom-left medium  
    {self.grid_cols, self.grid_rows, 15},  -- bottom-right bright
    {math.ceil(self.grid_cols/2), math.ceil(self.grid_rows/2), 5}  -- center dim
  }
  
  for _, pos in ipairs(test_positions) do
    local x, y, brightness = pos[1], pos[2], pos[3]
    if x <= self.grid_cols and y <= self.grid_rows then
      self.g:led(x, y, brightness)
      print(string.format("grid_service: test LED at (%d,%d) brightness %d", x, y, brightness))
    end
  end
  
  self.g:refresh()
  print("grid_service: basic test pattern displayed")
  return true
end

function GridService:test_vu_display()
  if not self:is_ready() then
    print("grid_service: VU test failed - grid not ready")
    return false
  end
  
  print("grid_service: testing VU display...")
  self.g:all(0)
  
  -- Test VU columns
  local test_x = math.ceil(self.grid_cols / 2)
  local test_lit = math.ceil(self.grid_rows / 2)
  
  print(string.format("grid_service: VU test - x=%d lit_rows=%d total_rows=%d", test_x, test_lit, self.grid_rows))
  
  for i = 0, test_lit - 1 do
    local y = self.grid_rows - i
    if y >= 1 and y <= self.grid_rows then
      self.g:led(test_x, y, 12)
      print(string.format("grid_service: VU test LED at (%d,%d)", test_x, y))
    end
  end
  
  -- Add heartbeat for reference
  self.g:led(1, 1, 8)
  
  self.g:refresh()
  print("grid_service: VU test pattern displayed")
  return true
end

return GridService
