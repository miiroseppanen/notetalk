-- notetalk
-- Speek to notes
-- Kantama
-- v1.0.0 @2026
--  

-- Engine change can corrupt JACK state - use default engine instead
-- engine.name = "PolyPerc"

local fileselect = require "fileselect"
local musicutil = require "musicutil"

-- Käytä midigrid-kirjastoa jos saatavilla (Launchpad jne.) – muuten vakio grid
-- Kahdelle Launchpadille käytetään midigrid_2pages tai mg_128 (16x8)
local grid
do
  -- Kokeile ensin 16x8 versiota (kahdelle Launchpadille)
  local ok, mg = pcall(function() return include("midigrid/lib/midigrid_2pages") end)
  if not (ok and mg) and _path.code then
    ok, mg = pcall(function() return include(_path.code .. "midigrid/lib/midigrid_2pages") end)
  end
  -- Jos ei löydy, kokeile mg_128
  if not (ok and mg) then
    ok, mg = pcall(function() return include("midigrid/lib/mg_128") end)
  end
  if not (ok and mg) and _path.code then
    ok, mg = pcall(function() return include(_path.code .. "midigrid/lib/mg_128") end)
  end
  -- Jos ei löydy, käytä tavallista midigrid (8x8)
  if not (ok and mg) then
    ok, mg = pcall(function() return include("midigrid/lib/midigrid") end)
  end
  if not (ok and mg) and _path.code then
    ok, mg = pcall(function() return include(_path.code .. "midigrid/lib/midigrid") end)
  end
  if ok and mg then
    grid = mg
  else
    grid = require "grid"
  end
end

local Analyzer = include("lib/analyzer")
local Mapping = include("lib/mapping")
local MidiOut = include("lib/midi_out")
-- Grid service replaced with direct grid handling
local AudioService = include("lib/audio_service")

local analyzer
local midi_out
local grid_redraw_metro = nil
local audio_service

local state = {
  freeze = false,
  sample_loaded = false,
  sample_path = nil,
  source_label = "line in",
  last_event_hz = nil,
  last_event_midi = nil,
  last_event_conf = 0,
  last_event_amp = 0,
  amp_out_l = 0,
  amp_out_r = 0,
  amp_in_l = 0,
  amp_in_r = 0,
  pitch_hz = nil,
  pitch_conf = 0,
  amp_norm = 0,
  amp_pulse = 0,
  amp_floor_est = 0,
  amp_ceil_est = 0.1,
  pitch_midi = nil,
  onset_event = false,
  now_ms = 0,
  debug_hit_count = 0,
  debug_last_trigger_ms = -10000,
  voiced_pitch_last_ms = -10000,
  phase_wrap_count = 0,
  phase_event_count = 0,
  phase_moving = false,
  phase_last_t = 0,
  phase_last_pos = nil,
  phase_pulse_t = 0,
  amp_poll_restart_warned = false,
  vu_level = 0,  -- VU-mittarille: hitaasti decaytaava taso
  vu_test_mode = true,  -- Testi-VU-animaatio päällä (vaihdetaan parametrista)
}

local amp_poll = nil
local amp_poll_aux = nil
local amp_poll_in_l = nil
local amp_poll_in_r = nil
local pitch_poll = nil
local conf_poll = nil
local pitch_retry_metro = nil
local analysis_clock = nil
local redraw_clock = nil

local g = nil
local grid_cols = 0
local grid_rows = 0
local last_valid_x = nil
local last_grid_debug = 0
local onset_x = nil
local active_line_y = nil
local active_line_t0 = nil
local set_active_line_from_event = nil

local LINE_FADE_MS = 500
local DEBUG_SAMPLE_RELATIVE_PATH = "kantama/finland.wav"
local DEBUG_RUN_ID = "grid-note-plan-v1"

local SCALE_NAMES = Mapping.get_scale_names()
local debug_last_log_at = {}
local voiced_pitch_samples = {}
local VOICED_PITCH_CAP = 9
local GRID_RECOVER_TICKS = 120
local grid_not_ready_ticks = 0
local deferred_clocks = {}
local ENABLE_PHASE_MONITOR = false
local phase_monitor_active = false
local softcut_active = false
local ENABLE_DEBUG_AUTOSAMPLE = true
local DEBUG_ENABLED = true

-- Softcut phase monitoring now handled by AudioService

local function defer_clock(fn)
  local id = clock.run(fn)
  table.insert(deferred_clocks, id)
  return id
end

local function source_is_sample()
  local mode = params:string("input_mode")
  local sample_enabled = params:string("sample_enabled") == "on"
  return mode == "softcut" and sample_enabled and state.sample_loaded
end

local function debug_json_escape(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\"):gsub("\"", "\\\"")
  text = text:gsub("\n", "\\n"):gsub("\r", "\\r")
  return text
end

local function debug_json_kv(key, value)
  local value_type = type(value)
  if value_type == "number" or value_type == "boolean" then
    return "\"" .. key .. "\":" .. tostring(value)
  end
  if value == nil then
    return "\"" .. key .. "\":null"
  end
  return "\"" .. key .. "\":\"" .. debug_json_escape(value) .. "\""
end

local function debug_log(_hypothesis_id, _location, _message, _data)
  -- Debug logging disabled
end

local function debug_should_log(key, min_interval_sec)
  local now = util.time()
  local last = debug_last_log_at[key] or 0
  if (now - last) >= min_interval_sec then
    debug_last_log_at[key] = now
    return true
  end
  return false
end

local function clamp(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

local function round(value)
  if value >= 0 then
    return math.floor(value + 0.5)
  end
  return math.ceil(value - 0.5)
end

local function median_numbers(values)
  if #values == 0 then
    return nil
  end
  local sorted = {}
  for i = 1, #values do
    sorted[i] = values[i]
  end
  table.sort(sorted)
  local center = math.floor(#sorted / 2)
  if (#sorted % 2) == 1 then
    return sorted[center + 1]
  end
  return (sorted[center] + sorted[center + 1]) * 0.5
end

local function push_voiced_pitch(hz, now_ms)
  if not hz or hz <= 0 then
    return
  end
  voiced_pitch_samples[#voiced_pitch_samples + 1] = hz
  if #voiced_pitch_samples > VOICED_PITCH_CAP then
    table.remove(voiced_pitch_samples, 1)
  end
  state.voiced_pitch_last_ms = now_ms or state.now_ms
end

local function recent_voiced_pitch(now_ms, max_age_ms)
  local age_limit = max_age_ms or 700
  if (#voiced_pitch_samples == 0) or ((now_ms - (state.voiced_pitch_last_ms or -10000)) > age_limit) then
    return nil
  end
  return median_numbers(voiced_pitch_samples)
end

local function option_index(options, target)
  for i, value in ipairs(options) do
    if value == target then
      return i
    end
  end
  return 1
end

local function basename(path)
  if not path then
    return "none"
  end
  return path:match("([^/]+)$") or path
end






local function debug_system_status(force_log)
  if not DEBUG_ENABLED and not force_log then
    return
  end
  
  local audio_status = audio_service and audio_service:get_status() or {}
  local poll_status = {
    amp_poll = (amp_poll ~= nil),
    amp_poll_aux = (amp_poll_aux ~= nil),
    amp_poll_in_l = (amp_poll_in_l ~= nil),
    amp_poll_in_r = (amp_poll_in_r ~= nil),
    pitch_poll = (pitch_poll ~= nil),
    conf_poll = (conf_poll ~= nil)
  }
  
  local signal_levels = {
    amp_in_l = state.amp_in_l or 0,
    amp_in_r = state.amp_in_r or 0,
    amp_out_l = state.amp_out_l or 0,
    amp_out_r = state.amp_out_r or 0,
    total_amp = (state.amp_in_l or 0) + (state.amp_in_r or 0) + 
                (state.amp_out_l or 0) + (state.amp_out_r or 0)
  }
  
  debug_log("H18", "notetalk.lua:debug_system_status", "comprehensive_status", {
    runtime_ms = state.now_ms,
    sample_mode = source_is_sample(),
    input_mode = params:string("input_mode"),
    sample_enabled = params:string("sample_enabled"),
    sample_loaded = state.sample_loaded,
    sample_path = state.sample_path and basename(state.sample_path) or "none",
    audio_service = audio_status,
    polls = poll_status,
    signal_levels = signal_levels,
    processing = {
      amp_norm = state.amp_norm or 0,
      pitch_hz = state.pitch_hz or -1,
      pitch_conf = state.pitch_conf or 0,
      pitch_midi = state.pitch_midi or -1,
      threshold = params:get("threshold"),
      min_conf = params:get("min_conf")
    },
    grid_ready = (g ~= nil),
    hit_count = state.debug_hit_count
  })
  
end

local function current_scale_name()
  local index = params:get("scale")
  return SCALE_NAMES[index] or "chromatic"
end

local function current_pitch_midi()
  if not state.pitch_hz or state.pitch_hz <= 0 then
    return nil
  end
  return Mapping.hz_to_midi(state.pitch_hz)
end

local function grid_is_ready()
  return g ~= nil and grid_cols > 0 and grid_rows > 0
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

local function amp_to_lit_rows(amp_norm, vu_floor, rows)
  if rows < 1 then
    return 0
  end

  local floor_value = clamp(vu_floor, 0, 0.99)
  local amp_adj = clamp((clamp(amp_norm or 0, 0, 1) - floor_value) / (1 - floor_value), 0, 1)
  return clamp(round(amp_adj * rows), 0, rows)
end

local function threshold_to_y(threshold, vu_floor, rows)
  if rows < 1 then
    return 1
  end

  local floor_value = clamp(vu_floor, 0, 0.99)
  local thr_adj = clamp((clamp(threshold or 0, 0, 1) - floor_value) / (1 - floor_value), 0, 1)
  local thr_lit = clamp(round(thr_adj * rows), 0, rows)
  if thr_lit == 0 then
    return rows
  end
  return clamp(rows - thr_lit + 1, 1, rows)
end

local function update_source_label()
  if source_is_sample() then
    state.source_label = "sample"
  else
    state.source_label = "line in"
  end
end

local function apply_engine_settings()
  local synth_on = params:string("use_synth") == "on"
  local synth_level = params:get("synth_level")
  local reverb_send = params:get("fx_reverb_send")
  local delay_send = params:get("fx_delay_send")

  local target_level = synth_on and synth_level or 0
  pcall(function() audio.level_eng_cut(target_level) end)

  pcall(function() engine.level(target_level) end)
  pcall(function() engine.amp(target_level) end)
  pcall(function() engine.reverb_send(reverb_send) end)
  pcall(function() engine.delay_send(delay_send) end)
end

-- Moved to AudioService

local function load_sample(path, attempt)
  if not path or path == "" then
    return
  end
  attempt = attempt or 1
  local success = audio_service:load_sample(path, defer_clock)
  
  if success then
    state.sample_loaded = true
    state.sample_path = path
    local sl = params:get("sample_level")
    pcall(function() softcut.level(1, sl) end)
  else
    state.sample_loaded = false
    state.sample_path = nil
    if attempt < 2 then
      defer_clock(function()
        clock.sleep(0.2)
        if state.freeze then return end
        load_sample(path, attempt + 1)
      end)
    end
  end

  update_source_label()
  redraw()
end

local function play_boot_test_tone()
  defer_clock(function()
    clock.sleep(0.3)
    if state.freeze then return end
    pcall(function() engine.hz(440) end)
    pcall(function() engine.amp(0.35) end)
    clock.sleep(0.2)
    if state.freeze then return end
    pcall(function() engine.amp(0) end)
  end)
end

setup_softcut_phase_monitor = function()
  if not ENABLE_PHASE_MONITOR or phase_monitor_active then
    return
  end
  pcall(function() softcut.phase_quant(1, 0.125) end)
  pcall(function() softcut.poll_start_phase() end)
  pcall(function()
    softcut.event_phase(function(voice, position)
      if voice ~= 1 then
        return
      end

      local now_t = util.time()
      state.phase_event_count = state.phase_event_count + 1
      state.phase_moving = true
      state.phase_last_t = now_t

      local previous = state.phase_last_pos
      if previous and position < (previous - 0.2) then
        state.phase_wrap_count = state.phase_wrap_count + 1
        state.phase_pulse_t = now_t
        -- #region agent log
        debug_log("H7", "notetalk.lua:softcut.event_phase", "phase_wrap", {
          wraps = state.phase_wrap_count,
          events = state.phase_event_count,
          pos = position,
          prev = previous,
        })
        -- #endregion
      end
      state.phase_last_pos = position
    end)
  end)
  phase_monitor_active = true
end

clear_softcut_phase_monitor = function()
  if not phase_monitor_active then
    return
  end
  -- Set no-op first so no Lua callback runs during/after poll stop (avoids crone/JACK issues).
  pcall(function()
    softcut.event_phase(function(_, _) end)
  end)
  pcall(function()
    softcut.poll_stop_phase()
  end)
  phase_monitor_active = false
end

local function unload_sample()
  audio_service:unload_sample()
  state.sample_loaded = false
  state.sample_path = nil
  update_source_label()
  redraw()
end

local function midi_note_from_event(event)
  local midi_float = Mapping.hz_to_midi(event.hz)
  if not midi_float then
    return nil
  end

  midi_float = midi_float + (params:get("octave_shift") * 12)
  local quantized = Mapping.quantize_midi(midi_float, current_scale_name(), params:get("scale_root"))
  return Mapping.clamp_midi(quantized, params:get("midi_min"), params:get("midi_max"))
end

local function stabilized_event_hz(event_hz, now_ms)
  local hz = recent_voiced_pitch(now_ms, 700) or event_hz
  if not hz or hz <= 0 then
    return nil
  end

  local prev_hz = state.last_event_hz
  if prev_hz and prev_hz > 0 then
    local prev_midi = Mapping.hz_to_midi(prev_hz)
    local current_midi = Mapping.hz_to_midi(hz)
    if prev_midi and current_midi then
      local max_jump = 7
      local diff = current_midi - prev_midi
      if math.abs(diff) > max_jump then
        local clamped_midi = prev_midi + (diff > 0 and max_jump or -max_jump)
        hz = musicutil.note_num_to_freq(clamped_midi)
      end
    end
  end

  return hz
end

local function trigger_synth(note, amp)
  if params:string("use_synth") ~= "on" then
    return
  end

  local hz = musicutil.note_num_to_freq(note)
  local level = clamp(amp or 0.2, 0, 1)
  -- Keep triggers audible even when analysis amp is near threshold.
  level = clamp((0.15 + (level * 0.85)) * params:get("synth_level"), 0, 1)

  pcall(function() engine.hz(hz) end)

  -- Prefer gated engines when available; otherwise trigger as one-shot.
  local ok_note_on = pcall(function() engine.noteOn(level) end)
  if ok_note_on then
    defer_clock(function()
      clock.sleep(params:get("note_length_ms") / 1000)
      if state.freeze then return end
      pcall(function() engine.noteOff() end)
    end)
  else
    pcall(function() engine.amp(level) end)
  end
end

local function handle_analysis_event(event)
  local hz = stabilized_event_hz(event.hz, state.now_ms)
  if not hz then
    return
  end
  event.hz = hz
  state.onset_event = true
  set_active_line_from_event(event)

  local note = midi_note_from_event(event)
  if not note then
    return
  end

  state.last_event_hz = event.hz
  state.last_event_midi = note
  state.last_event_conf = event.confidence
  state.last_event_amp = event.amp

  midi_out:set_note_length_ms(params:get("note_length_ms"))
  midi_out:trigger_note(note, event.amp)
  trigger_synth(note, event.amp)
  -- Enhanced debug logging for note triggering
  debug_log("H4", "notetalk.lua:handle_analysis_event", "triggered_note", {
    note = note,
    hz = event.hz,
    amp = event.amp or 0,
    confidence = event.confidence or 0,
    sample_mode = source_is_sample(),
    synth_on = params:string("use_synth"),
    synth_level = params:get("synth_level"),
    midi_send = params:string("midi_send"),
    scale = current_scale_name(),
    octave_shift = params:get("octave_shift"),
    input_mode = params:string("input_mode"),
    sample_enabled = params:string("sample_enabled"),
    sample_loaded = state.sample_loaded,
    current_amp_norm = state.amp_norm or 0,
    current_threshold = params:get("threshold")
  })
  
  redraw()
end

local function setup_polls()
  local function try_poll(name, callback)
    local ok, poll_obj = pcall(poll.set, name)
    if ok and poll_obj then
      poll_obj.time = 0.03
      poll_obj.callback = callback
      poll_obj:start()
      return poll_obj
    end
    return nil
  end

  -- Read multiple amp taps and use whichever gives strongest signal.
  amp_poll = try_poll("amp_out_l", function(value) state.amp_out_l = math.abs(value or 0) end)
  amp_poll_aux = try_poll("amp_out_r", function(value) state.amp_out_r = math.abs(value or 0) end)
  amp_poll_in_l = try_poll("amp_in_l", function(value) state.amp_in_l = math.abs(value or 0) end)
  amp_poll_in_r = try_poll("amp_in_r", function(value) state.amp_in_r = math.abs(value or 0) end)

  local pitch_poll_name = "none"
  local conf_poll_name = "none"
  local pitch_poll_names = {"pitch_in", "pitch_out", "pitch", "in_pitch"}
  local conf_poll_names = {"pitch_conf", "pitch_out_conf", "conf", "pitch_confidence", "in_pitch_conf"}

  local function try_setup_pitch_and_conf()
    if not pitch_poll then
      for _, name in ipairs(pitch_poll_names) do
        pitch_poll = try_poll(name, function(value) state.pitch_hz = value end)
        if pitch_poll then
          pitch_poll_name = name
          break
        end
      end
    end

    if not conf_poll then
      for _, name in ipairs(conf_poll_names) do
        conf_poll = try_poll(name, function(value) state.pitch_conf = value end)
        if conf_poll then
          conf_poll_name = name
          break
        end
      end
    end
  end

  try_setup_pitch_and_conf()

  -- #region agent log
  debug_log("H6", "notetalk.lua:setup_polls", "poll_selection", {
    amp_out_l = (amp_poll and "set" or "none"),
    amp_out_r = (amp_poll_aux and "set" or "none"),
    amp_in_l = (amp_poll_in_l and "set" or "none"),
    amp_in_r = (amp_poll_in_r and "set" or "none"),
    pitch_poll = pitch_poll_name,
    conf_poll = conf_poll_name,
  })
  -- #endregion

  if (not pitch_poll) or (not conf_poll) then
    if pitch_retry_metro then
      pitch_retry_metro:stop()
      pitch_retry_metro = nil
    end
    pitch_retry_metro = metro.init()
    if pitch_retry_metro then
      pitch_retry_metro.time = 1
      pitch_retry_metro.event = function()
        local had_pitch = (pitch_poll ~= nil)
        local had_conf = (conf_poll ~= nil)
        try_setup_pitch_and_conf()
        local has_pitch = (pitch_poll ~= nil)
        local has_conf = (conf_poll ~= nil)
        if (had_pitch ~= has_pitch) or (had_conf ~= has_conf) or debug_should_log("poll_retry", 4.0) then
          -- #region agent log
          debug_log("H6", "notetalk.lua:setup_polls", "poll_retry_status", {
            pitch_poll = pitch_poll_name,
            conf_poll = conf_poll_name,
            has_pitch = has_pitch,
            has_conf = has_conf,
          })
          -- #endregion
        end
        if has_pitch and has_conf and pitch_retry_metro then
          pitch_retry_metro:stop()
          pitch_retry_metro = nil
        end
      end
      pitch_retry_metro:start()
    else
    end
  end
  
  -- Enhanced health check for amp polls with detailed monitoring
  if state.now_ms and state.now_ms > 5000 then -- Only after 5 seconds of runtime
    local total_amp = (state.amp_in_l or 0) + (state.amp_in_r or 0) + (state.amp_out_l or 0) + (state.amp_out_r or 0)
    local sample_mode = source_is_sample()
    local audio_service_status = audio_service and audio_service:get_status() or {}
    
    if total_amp <= 0.0001 and not state.amp_poll_restart_warned then
      debug_log("H13", "notetalk.lua:setup_polls", "amp_polls_dead", {
        amp_in_l = state.amp_in_l or -1,
        amp_in_r = state.amp_in_r or -1, 
        amp_out_l = state.amp_out_l or -1,
        amp_out_r = state.amp_out_r or -1,
        total_amp = total_amp,
        sample_mode = sample_mode,
        sample_loaded = audio_service_status.sample_loaded or false,
        softcut_active = audio_service_status.softcut_active or false,
        polls_active = {
          amp_poll = (amp_poll ~= nil),
          amp_poll_aux = (amp_poll_aux ~= nil),
          amp_poll_in_l = (amp_poll_in_l ~= nil),
          amp_poll_in_r = (amp_poll_in_r ~= nil)
        }
      })
      
      -- Try to restart amp polls
      if amp_poll then amp_poll:stop(); amp_poll = nil; end
      if amp_poll_aux then amp_poll_aux:stop(); amp_poll_aux = nil; end
      if amp_poll_in_l then amp_poll_in_l:stop(); amp_poll_in_l = nil; end
      if amp_poll_in_r then amp_poll_in_r:stop(); amp_poll_in_r = nil; end
      
      amp_poll = try_poll("amp_out_l", function(value) state.amp_out_l = math.abs(value or 0) end)
      amp_poll_aux = try_poll("amp_out_r", function(value) state.amp_out_r = math.abs(value or 0) end)
      amp_poll_in_l = try_poll("amp_in_l", function(value) state.amp_in_l = math.abs(value or 0) end)
      amp_poll_in_r = try_poll("amp_in_r", function(value) state.amp_in_r = math.abs(value or 0) end)
      
      -- If sample mode, also try to re-establish audio routing
      if sample_mode and audio_service then
        audio_service:ensure_monitor_routing()
      end
      
      state.amp_poll_restart_warned = true
    end
    
    -- Periodic health status logging
    if debug_should_log("system_health", 10.0) then
      debug_log("H17", "notetalk.lua:setup_polls", "system_health_status", {
        total_amp = total_amp,
        sample_mode = sample_mode,
        sample_loaded = audio_service_status.sample_loaded or false,
        amp_norm = state.amp_norm or 0,
        pitch_hz = state.pitch_hz or -1,
        pitch_conf = state.pitch_conf or 0,
        runtime_ms = state.now_ms,
        polls_healthy = total_amp > 0.0001
      })
    end
  end
end

local function cleanup_polls()
  if amp_poll then amp_poll:stop() end
  if amp_poll_aux then amp_poll_aux:stop() end
  if amp_poll_in_l then amp_poll_in_l:stop() end
  if amp_poll_in_r then amp_poll_in_r:stop() end
  if pitch_poll then pitch_poll:stop() end
  if conf_poll then conf_poll:stop() end
  if pitch_retry_metro then pitch_retry_metro:stop() end
  amp_poll = nil
  amp_poll_aux = nil
  amp_poll_in_l = nil
  amp_poll_in_r = nil
  pitch_poll = nil
  conf_poll = nil
  pitch_retry_metro = nil
end

local function add_input_params()
  params:add_separator("input_sep", "Input")
  params:add_option("input_mode", "Input Mode", {"audio_in", "softcut"}, 1)
  params:set_action("input_mode", function()
    update_source_label()
    redraw()
  end)

  params:add_option("sample_enabled", "Sample Source", {"off", "on"}, 1)
  params:set_action("sample_enabled", function()
    update_source_label()
    redraw()
  end)

  params:add_trigger("load_sample", "Load Sample")
  params:set_action("load_sample", function()
    fileselect.enter(_path.audio, function(path) load_sample(path) end)
  end)

  params:add_trigger("clear_sample", "Clear Sample")
  params:set_action("clear_sample", function() unload_sample() end)

  params:add_control("sample_level", "Sample Level", controlspec.new(0, 1, "lin", 0, 1.0, ""))
  params:set_action("sample_level", function(value)
    pcall(function() softcut.level(1, value) end)
  end)
end

local function add_analysis_params()
  params:add_separator("analysis_sep", "Analysis")
  params:add_control("threshold", "Threshold", controlspec.new(0.001, 1, "lin", 0, 0.05, ""))
  params:set_action("threshold", function(value)
    analyzer:set_threshold(value)
  end)

  params:add_control("min_conf", "Min Confidence", controlspec.new(0, 1, "lin", 0, 0.45, ""))
  params:set_action("min_conf", function(value)
    analyzer:set_min_conf(value)
  end)

  params:add_number("hold_ms", "Gate Hold (ms)", 10, 1000, 140)
  params:set_action("hold_ms", function(value)
    analyzer:set_hold_ms(value)
  end)

  params:add_number("window_ms", "Pitch Window (ms)", 20, 800, 120)
  params:set_action("window_ms", function(value)
    analyzer:set_window_ms(value)
  end)
end

local function add_mapping_params()
  params:add_separator("mapping_sep", "Mapping")
  params:add_option("scale", "Scale", SCALE_NAMES, 2)
  params:add_number("scale_root", "Scale Root (semitone)", 0, 11, 0)
  params:add_number("octave_shift", "Octave Shift", -3, 3, 0)
  params:add_number("midi_min", "MIDI Min", 0, 127, 36)
  params:add_number("midi_max", "MIDI Max", 0, 127, 96)
end

local function add_midi_params()
  params:add_separator("midi_sep", "MIDI Output")
  params:add_option("midi_send", "Send MIDI", {"off", "on"}, 1)
  params:set_action("midi_send", function(value)
    midi_out:set_send_enabled(value == 2)
  end)

  local midi_devices = MidiOut.list_devices()
  params:add_option("midi_device", "MIDI Device", midi_devices, 1)
  params:set_action("midi_device", function(value)
    if #midi.vports > 0 then
      midi_out:set_device(value)
    end
  end)

  params:add_number("midi_channel", "MIDI Channel", 1, 16, 1)
  params:set_action("midi_channel", function(value)
    midi_out:set_channel(value)
  end)

  params:add_number("note_length_ms", "Note Length (ms)", 10, 4000, 150)
  params:set_action("note_length_ms", function(value)
    midi_out:set_note_length_ms(value)
  end)

  params:add_option("velocity_mode", "Velocity Mode", {"amp", "fixed"}, 1)
  params:set_action("velocity_mode", function(value)
    midi_out:set_velocity_mode(value == 2 and "fixed" or "amp")
  end)

  params:add_number("fixed_velocity", "Fixed Velocity", 1, 127, 100)
  params:set_action("fixed_velocity", function(value)
    midi_out:set_fixed_velocity(value)
  end)
end

local function add_synth_and_fx_params()
  params:add_separator("synth_sep", "Synth and FX")
  params:add_option("use_synth", "Use Synth", {"off", "on"}, 2)
  params:set_action("use_synth", function() apply_engine_settings() end)

  params:add_control("synth_level", "Synth Level", controlspec.new(0, 1, "lin", 0, 0.6, ""))
  params:set_action("synth_level", function() apply_engine_settings() end)

  params:add_control("fx_reverb_send", "FX Reverb Send", controlspec.new(0, 1, "lin", 0, 0.2, ""))
  params:set_action("fx_reverb_send", function() apply_engine_settings() end)

  params:add_control("fx_delay_send", "FX Delay Send", controlspec.new(0, 1, "lin", 0, 0.1, ""))
  params:set_action("fx_delay_send", function() apply_engine_settings() end)
end

local function add_grid_visualizer_params()
  params:add_separator("grid_viz_sep", "Grid Visualizer")
  params:add_control("vu_floor", "VU Floor", controlspec.new(0, 0.5, "lin", 0, 0.08, ""))
  params:add_number("pitch_min_midi", "Pitch Min MIDI", 0, 127, 36)
  params:add_number("pitch_max_midi", "Pitch Max MIDI", 0, 127, 96)
  params:add_option("vu_mode", "VU Mode", {"column", "wide"}, 2)
  params:add_option("line_mode", "Line Mode", {"threshold", "onset"}, 1)
  params:add_option("vu_test_mode", "VU Test Animation", {"off", "on"}, 2)  -- Oletuksena päällä
  params:set_action("vu_test_mode", function(value)
    state.vu_test_mode = (value == 2)
  end)
end

local function apply_grid_defaults_for_size(cols, rows)
  if cols <= 0 or rows <= 0 then
    return
  end

  if cols <= 8 and rows <= 8 then
    params:set("vu_mode", option_index({"column", "wide"}, "column"))
    params:set("pitch_min_midi", 48)
    params:set("pitch_max_midi", 84)
  else
    params:set("vu_mode", option_index({"column", "wide"}, "wide"))
    params:set("pitch_min_midi", 36)
    params:set("pitch_max_midi", 96)
  end
end

local function setup_params()
  params:add_separator("script_sep", "notetalk")
  add_input_params()
  add_analysis_params()
  add_mapping_params()
  add_midi_params()
  add_synth_and_fx_params()
  add_grid_visualizer_params()
  params:bang()
end

local function setup_debug_sample_defaults()
  local debug_path = _path.audio .. DEBUG_SAMPLE_RELATIVE_PATH
  local info_ok = pcall(audio.file_info, debug_path)
  if not info_ok then
    return
  end
  params:set("input_mode", option_index({"audio_in", "softcut"}, "softcut"))
  params:set("sample_enabled", option_index({"off", "on"}, "on"))
  params:set("use_synth", option_index({"off", "on"}, "on"))
  params:set("midi_send", option_index({"off", "on"}, "off"))
  params:set("threshold", 0.01)
  params:set("min_conf", 0.2)
  params:set("window_ms", 140)
  params:set("note_length_ms", 180)
  params:set("sample_level", 1.0)
  params:set("synth_level", 0.8)
  load_sample(debug_path)
end

local function schedule_debug_sample_defaults()
  defer_clock(function()
    -- Short delay avoids first-frame race while keeping startup autoload behavior.
    clock.sleep(0.25)
    if state.freeze then
      return
    end
    setup_debug_sample_defaults()
  end)
end

local function draw_grid()
  if not g then return end
  
  local cols = grid_cols or g.cols or 16
  local rows = grid_rows or g.rows or 8
  if cols < 1 or rows < 1 then return end
  
  local ok, err = pcall(function()
    g:all(0)
    
    local vu_floor = 0.02
    local vu_mode = "wide"
    pcall(function()
      vu_floor = params:get("vu_floor") or vu_floor
      vu_mode = params:string("vu_mode") or vu_mode
    end)
    
    -- Spektrogrammi-VU: jokaiselle sarakkeelle oma taajuus/amplitudi
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
      local direct_amp = 0
      if sample_mode then
        direct_amp = math.max(state.amp_out_l or 0, state.amp_out_r or 0)
      else
        direct_amp = math.max(state.amp_in_l or 0, state.amp_in_r or 0)
      end
      
      local vu_from_level = clamp(state.vu_level or 0, 0, 1)
      local vu_from_polls = math.min(1, direct_amp * 50)
      local vu_amp = math.max(vu_from_level, vu_from_polls)
      
      local pitch_min = params:get("pitch_min_midi") or 36
      local pitch_max = params:get("pitch_max_midi") or 96
      local pitch_x = nil
      if state.pitch_midi and state.pitch_midi >= pitch_min and state.pitch_midi <= pitch_max then
        pitch_x = pitch_to_x(state.pitch_midi, cols, pitch_min, pitch_max)
      end
      
      for x = 1, cols do
        local col_amp = 0
        if pitch_x and x == pitch_x then
          col_amp = vu_amp * 1.2
        else
          col_amp = vu_amp * 0.3
        end
        col_amp = clamp(col_amp, 0, 1)
        
        if col_amp > 0.01 then
          local lit_rows_for_col = math.max(1, round(col_amp * rows))
          for i = 0, lit_rows_for_col - 1 do
            local y = rows - i
            if y >= 1 and y <= rows then
              local brightness = clamp(4 + round(11 * (i / math.max(1, lit_rows_for_col - 1))), 4, 15)
              g:led(x, y, brightness)
            end
          end
        end
      end
      
      if vu_amp < 0.01 then
        local y_bottom = rows
        for x = 1, cols do
          g:led(x, y_bottom, 1)
        end
      end
    end
    
    g:refresh()
  end)
  if not ok and err then
  end
end

set_active_line_from_event = function(event)
  -- Grid line effects can be added here later if needed
  -- For now, VU meter in draw_grid() is sufficient
end


local function setup_grid()
  -- Käytä suoraa grid.connect(1) kuten standardi grid-API (midigrid hoitaa automaattisesti)
  g = grid.connect(1)
  
  if g then
    -- Käytä gridin raportoimia dimensioita suoraan (midigrid asettaa ne automaattisesti)
    grid_cols = g.cols or 16
    grid_rows = g.rows or 8
    
    -- Jos dimensiot ovat 0 tai puuttuvat, aseta oletukset
    if grid_cols == 0 or grid_rows == 0 then
      grid_cols = 16
      grid_rows = 8
    end
    
    -- Varmista että dimensiot ovat asetettu grid-olioon
    if g.cols then g.cols = grid_cols end
    if g.rows then g.rows = grid_rows end
    
    apply_grid_defaults_for_size(grid_cols, grid_rows)
    
    g.key = function(x, y, z) end
    
    draw_grid()
    
    if grid_redraw_metro then
      pcall(function() grid_redraw_metro:stop() end)
      grid_redraw_metro = nil
    end
    grid_redraw_metro = metro.init()
    if grid_redraw_metro then
      grid_redraw_metro.time = 1 / 30
      grid_redraw_metro.event = function() draw_grid() end
      grid_redraw_metro:start()
    end
    
    grid.add = function()
      setup_grid()
    end
  end
end

local function analyzer_loop()
  local previous_amp = 0
  local poll_check_counter = 0

  while true do
    clock.sleep(1 / 60)
    state.now_ms = state.now_ms + (1000 / 60)
    state.onset_event = false

    if state.freeze then
      goto continue
    end
    
    -- Check poll health every ~1 second (60 loops / 60 = 1 sec)
    poll_check_counter = poll_check_counter + 1
    if poll_check_counter >= 60 then
      poll_check_counter = 0
      setup_polls() -- This will now auto-restart dead amp polls
    end

    update_source_label()

    local sample_mode = source_is_sample()
    local amp_raw = 0
    
    if sample_mode then
      -- For sample mode, prioritize output channels as they carry the softcut signal
      -- Monitor inputs as secondary since they may have noise floor issues
      local amp_out = math.max(state.amp_out_l or 0, state.amp_out_r or 0)
      local amp_in = math.max(state.amp_in_l or 0, state.amp_in_r or 0)
      
      -- Use output as primary, input as fallback
      amp_raw = math.max(amp_out, amp_in * 0.7)
      
      -- Fallback detection: if all polls are near zero but we have a sample loaded,
      -- trigger audio service to re-establish monitor routing
      if amp_raw < 0.0001 and audio_service and state.sample_loaded then
        audio_service:ensure_monitor_routing()
        if debug_should_log("routing_fallback", 3.0) then
          debug_log("H15", "notetalk.lua:analyzer_loop", "routing_fallback_triggered", {
            amp_out_l = state.amp_out_l or -1,
            amp_out_r = state.amp_out_r or -1,
            amp_in_l = state.amp_in_l or -1,
            amp_in_r = state.amp_in_r or -1,
            sample_loaded = state.sample_loaded
          })
        end
      end
    else
      -- For line-in mode, prioritize input channels
      local amp_in = math.max(state.amp_in_l or 0, state.amp_in_r or 0)
      local amp_out = math.max(state.amp_out_l or 0, state.amp_out_r or 0)
      
      -- Use input as primary, output as fallback
      amp_raw = math.max(amp_in, amp_out * 0.5)
    end
    
    -- Debug: check if we're getting signal
    if debug_should_log("signal_check", 5.0) then
      debug_log("H12", "notetalk.lua:analyzer_loop", "signal_values", {
        amp_raw = amp_raw,
        amp_in_l = state.amp_in_l or -1,
        amp_in_r = state.amp_in_r or -1,
        amp_out_l = state.amp_out_l or -1,
        amp_out_r = state.amp_out_r or -1,
        pitch_hz = state.pitch_hz or -1,
        pitch_conf = state.pitch_conf or -1,
        sample_mode = sample_mode,
        polls_active = {
          amp_poll = (amp_poll ~= nil),
          amp_poll_aux = (amp_poll_aux ~= nil),
          pitch_poll = (pitch_poll ~= nil),
          conf_poll = (conf_poll ~= nil),
          pitch_retry_metro = (pitch_retry_metro ~= nil)
        }
      })
    end
    local amp = clamp(amp_raw, 0, 1)
    local pitch = state.pitch_hz
    local confidence = clamp(state.pitch_conf or 0, 0, 1)
    local min_conf = params:get("min_conf")
    if pitch and pitch > 0 and confidence >= min_conf then
      push_voiced_pitch(pitch, state.now_ms)
    end

    local amp_trigger_metric = amp_raw  -- Always use raw signal for trigger detection
    
    if sample_mode then
      -- Improved adaptive normalization with better edge case handling
      local min_floor = 0.0001  -- Prevent floor from going too low
      local max_ceil_ratio = 50.0  -- Prevent excessive ceiling growth
      
      -- Update floor estimate with bounds checking
      state.amp_floor_est = math.max(min_floor, 
        (state.amp_floor_est * 0.995) + (amp_raw * 0.005))
      
      -- Update ceiling with controlled growth and decay
      if amp_raw > state.amp_ceil_est then
        state.amp_ceil_est = amp_raw
      else
        state.amp_ceil_est = math.max(
          state.amp_floor_est * 2.0,  -- Minimum viable ceiling
          state.amp_ceil_est * 0.9995  -- Very slow decay
        )
      end
      
      -- Prevent excessive ceiling growth
      if state.amp_ceil_est > (state.amp_floor_est * max_ceil_ratio) then
        state.amp_ceil_est = state.amp_floor_est * max_ceil_ratio
      end
      
      local span_for_amp = math.max(0.01, state.amp_ceil_est - state.amp_floor_est)
      local normalized_amp = clamp((amp_raw - state.amp_floor_est) / span_for_amp, 0, 1)
      
      -- Use normalized amp for display/grid, raw for triggering
      amp = normalized_amp
      
      if debug_should_log("normalization", 4.0) then
        debug_log("H14", "notetalk.lua:analyzer_loop", "normalization", {
          amp_raw = amp_raw,
          amp_normalized = normalized_amp,
          amp_trigger_metric = amp_trigger_metric,
          amp_floor_est = state.amp_floor_est,
          amp_ceil_est = state.amp_ceil_est,
          span = span_for_amp,
          floor_bound_applied = (state.amp_floor_est == min_floor),
          ceiling_bound_applied = (state.amp_ceil_est == state.amp_floor_est * max_ceil_ratio)
        })
      end
    else
      -- For line-in mode, use raw signal directly
      amp = amp_raw
      amp_trigger_metric = amp_raw
    end

    if sample_mode and (pitch == nil or pitch <= 0 or confidence < min_conf) then
      -- Fallback pitch: map current amplitude to MIDI range (more expressive than fixed pitch).
      pitch = recent_voiced_pitch(state.now_ms, 700)
      if not pitch then
        local midi_min = params:get("midi_min")
        local midi_max = params:get("midi_max")
        local amp_norm_pitch = clamp(amp, 0, 1)
        local amp_midi = midi_min + round(amp_norm_pitch * (midi_max - midi_min))
        pitch = musicutil.note_num_to_freq(clamp(amp_midi, midi_min, midi_max))
      end
      confidence = 1
    end

    state.amp_pulse = state.amp_pulse * 0.9
    state.amp_norm = math.max(amp, state.amp_pulse)
    state.pitch_midi = current_pitch_midi()
    
    -- VU: käytä suoraan raakaa signaalia ilman normalisointia, vahvistus jotta palkki liikkuu
    -- Sample-tilassa käytä ulostuloa, line-in-tilassa sisääntuloa
    local vu_raw = 0
    if sample_mode then
      vu_raw = math.max(state.amp_out_l or 0, state.amp_out_r or 0)
    else
      vu_raw = math.max(state.amp_in_l or 0, state.amp_in_r or 0)
    end
    
    -- Vahvista signaali ja käytä decay-logiikkaa
    local vu_scaled = math.min(1, vu_raw * 15)  -- Vahva vahvistus
    local instant = math.max(vu_scaled, state.amp_norm or 0)
    state.vu_level = math.max(instant, (state.vu_level or 0) * 0.99)  -- Hitaampi decay

    -- Sample-mode trigger from transients, not fixed clock.
    local threshold = params:get("threshold")
    local effective_threshold = threshold
    
    if sample_mode then
      -- Adaptive threshold based on current signal characteristics
      local min_threshold = math.max(0.001, state.amp_floor_est * 1.5)
      local max_threshold = math.min(0.15, state.amp_ceil_est * 0.3)
      
      -- Allow user threshold but constrain to reasonable bounds
      effective_threshold = clamp(threshold, min_threshold, max_threshold)
      
      -- If normalized amp is being used for display, adjust threshold accordingly
      if state.amp_ceil_est > state.amp_floor_est then
        local norm_threshold = (effective_threshold - state.amp_floor_est) / 
                              (state.amp_ceil_est - state.amp_floor_est)
        norm_threshold = clamp(norm_threshold, 0.05, 0.8)
        -- Keep original threshold for raw signal comparison
      end
      
      if debug_should_log("threshold_adaptation", 3.0) then
        debug_log("H11", "notetalk.lua:analyzer_loop", "threshold_adaptation", {
          threshold_user = threshold,
          threshold_effective = effective_threshold,
          min_threshold = min_threshold,
          max_threshold = max_threshold,
          amp_floor_est = state.amp_floor_est,
          amp_ceil_est = state.amp_ceil_est,
          sample_mode = sample_mode,
        })
      end
    end
    local amp_delta = amp_trigger_metric - previous_amp
    local onset_candidate = amp_trigger_metric >= effective_threshold
    local onset_rise_ok = amp_delta >= 0.004
    local refractory_ok = (state.now_ms - state.debug_last_trigger_ms) >= params:get("hold_ms")
    local onset_accept = onset_candidate and onset_rise_ok and refractory_ok
    if debug_should_log("onset_stage", 1.0) then
      -- #region agent log
      debug_log("H3", "notetalk.lua:analyzer_loop", "onset_stage", {
        onset_candidate = onset_candidate,
        onset_rise_ok = onset_rise_ok,
        refractory_ok = refractory_ok,
        onset_accept = onset_accept,
        amp_delta = amp_delta,
        amp = amp,
        amp_trigger_metric = amp_trigger_metric,
        amp_prev = previous_amp,
        threshold = effective_threshold,
        sample_mode = sample_mode,
        hold_ms = params:get("hold_ms"),
      })
      -- #endregion
    end
    if onset_accept then
      -- #region agent log
      debug_log("H3", "notetalk.lua:analyzer_loop", "trigger_branch", {
        threshold_cross = onset_candidate,
        amp_rise_trigger = onset_rise_ok,
        recovery_trigger = false,
        amp = amp,
        amp_trigger_metric = amp_trigger_metric,
        amp_prev = previous_amp,
        threshold = effective_threshold,
        sample_mode = sample_mode,
        hold_ms = params:get("hold_ms"),
      })
      -- #endregion
      state.debug_hit_count = state.debug_hit_count + 1
      state.debug_last_trigger_ms = state.now_ms
      local trigger_amp = clamp(math.max(amp_trigger_metric, effective_threshold * 1.2), 0, 1)
      state.amp_pulse = math.max(state.amp_pulse, trigger_amp)
      -- #region agent log
      debug_log("H8", "notetalk.lua:analyzer_loop", "fallback_event_emit", {
        trigger_amp = trigger_amp,
        hz = (pitch and pitch > 0) and pitch or 220,
        confidence = (confidence and confidence > 0) and confidence or 1,
        threshold_cross = onset_candidate,
        amp_rise_trigger = onset_rise_ok,
      })
      -- #endregion
      handle_analysis_event({
        hz = (pitch and pitch > 0) and pitch or 220,
        confidence = (confidence and confidence > 0) and confidence or 1,
        amp = trigger_amp,
      })
    end
    if debug_should_log("analyzer_summary", 2.0) then
      -- #region agent log
      debug_log("H2", "notetalk.lua:analyzer_loop", "analyzer_summary", {
        amp = amp,
        amp_trigger_metric = amp_trigger_metric,
        amp_raw = amp_raw,
        amp_floor_est = state.amp_floor_est,
        amp_ceil_est = state.amp_ceil_est,
        amp_out_l = state.amp_out_l or 0,
        amp_out_r = state.amp_out_r or 0,
        amp_in_l = state.amp_in_l or 0,
        amp_in_r = state.amp_in_r or 0,
        amp_prev = previous_amp,
        pitch_hz = pitch or -1,
        conf = confidence,
        hit_count = state.debug_hit_count,
        sample_mode = sample_mode,
        input_mode = params:string("input_mode"),
        sample_enabled = params:string("sample_enabled"),
        sample_loaded = state.sample_loaded,
        threshold = effective_threshold,
        threshold_user = threshold,
      })
      -- #endregion
    end
    
    previous_amp = amp_trigger_metric

    analyzer:process_observation(amp, pitch, confidence, state.now_ms)

    ::continue::
  end
end

local function redraw_loop()
  while true do
    clock.sleep(1 / 15)
    redraw()
  end
end

function init()
  if grid_redraw_metro then
    pcall(function() grid_redraw_metro:stop() end)
    grid_redraw_metro = nil
  end
  if analysis_clock then
    pcall(function() clock.cancel(analysis_clock) end)
    analysis_clock = nil
  end
  if redraw_clock then
    pcall(function() clock.cancel(redraw_clock) end)
    redraw_clock = nil
  end
  analyzer = Analyzer.new({
    threshold = 0.05,
    min_conf = 0.45,
    hold_ms = 140,
    window_ms = 120,
  })
  midi_out = MidiOut.new()
  audio_service = AudioService.new()

  audio_service:setup_defaults()
  setup_params()
  -- Aseta testi-tila parametrin mukaan
  state.vu_test_mode = (params:get("vu_test_mode") == 2)
  setup_polls()
  setup_grid()
  
  if ENABLE_DEBUG_AUTOSAMPLE then
    schedule_debug_sample_defaults()
  end
  update_source_label()
  apply_engine_settings()
  play_boot_test_tone()
  
  analysis_clock = clock.run(analyzer_loop)
  redraw_clock = clock.run(redraw_loop)
  redraw()
end

function enc(n, d)
  if n == 1 then
    params:delta("threshold", d)
  elseif n == 2 then
    -- Sample level - suora kontrolli
    local v = clamp(params:get("sample_level") + d * 0.01, 0, 1)
    params:set("sample_level", v)
    softcut.level(1, v)
  elseif n == 3 then
    -- Synth level - suora kontrolli
    local v = clamp(params:get("synth_level") + d * 0.01, 0, 1)
    params:set("synth_level", v)
    local synth_on = params:string("use_synth") == "on"
    local target_level = synth_on and v or 0
    engine.amp(target_level)
    engine.level(target_level)
  end
  redraw()
end

function key(n, z)
  if z == 1 then
    if n == 2 then
      state.freeze = not state.freeze
    elseif n == 3 then
      local test_event = {
        hz = 440,
        confidence = 1,
        amp = clamp(params:get("threshold") * 1.5, 0.05, 1),
      }
      handle_analysis_event(test_event)
    end
  end
  redraw()
end

function redraw()
  screen.clear()
  screen.level(15)
  screen.move(0, 10)
  screen.text("notetalk")

  screen.level(8)
  screen.move(0, 20)
  local freeze_text = state.freeze and "on" or "off"
  local sample_name = state.sample_loaded and basename(state.sample_path) or "none"
  screen.text("src:" .. state.source_label .. " freeze:" .. freeze_text)

  screen.move(0, 30)
  screen.text("sample:" .. sample_name)

  screen.move(0, 40)
  screen.text(string.format("thr %.3f conf %.2f", params:get("threshold"), params:get("min_conf")))

  screen.move(0, 50)
  screen.text("scale:" .. current_scale_name())

  screen.move(0, 60)
  local last_text = "last:none"
  if state.last_event_midi then
    last_text = string.format("last:n%d", state.last_event_midi)
  end
  screen.text(string.format("%s h:%d", last_text, state.debug_hit_count))

  -- Right-edge 1px volume meters: sample (left) and note/synth (right).
  local meter_bottom = 63
  local meter_top = 0
  local meter_height = 64
  local sample_level = clamp(params:get("sample_level") or 0, 0, 1)
  local synth_level = clamp(params:get("synth_level") or 0, 0, 1)
  local sample_pixels = clamp(round(sample_level * meter_height), 0, meter_height)
  local synth_pixels = clamp(round(synth_level * meter_height), 0, meter_height)

  -- Dim rails (always visible), then bright filled amount.
  screen.level(2)
  screen.move(125, meter_top)
  screen.line(125, meter_bottom)
  screen.stroke()
  screen.move(127, meter_top)
  screen.line(127, meter_bottom)
  screen.stroke()

  screen.level(15)
  if sample_pixels > 0 then
    screen.move(125, meter_bottom)
    screen.line(125, meter_bottom - sample_pixels + 1)
    screen.stroke()
  end
  if synth_pixels > 0 then
    screen.move(127, meter_bottom)
    screen.line(127, meter_bottom - synth_pixels + 1)
    screen.stroke()
  end

  screen.update()
end

function cleanup()
  -- Ultra-safe shutdown: cancel local callbacks/timers only, avoid backend audio calls during global restart.
  state.freeze = true
  
  -- Peruuta vain kelvolliset clock-id:t (väärä tyyppi aiheuttaa clock.resume -virheen)
  for _, id in ipairs(deferred_clocks) do
    if type(id) == "number" and id then
      pcall(clock.cancel, id)
    end
  end
  deferred_clocks = {}
  
  cleanup_polls()
  
  if midi_out then
    pcall(function() midi_out:cleanup() end)
  end
  
  -- Turvallinen metro-pysäytys
  if grid_redraw_metro then
    pcall(function() grid_redraw_metro:stop() end)
    grid_redraw_metro = nil
  end
  if pitch_retry_metro then
    pcall(function() pitch_retry_metro:stop() end)
    pitch_retry_metro = nil
  end
  
  -- Grid cleanup
  if g then
    pcall(function() g:all(0); g:refresh() end)
    g = nil
  end
  
  -- ENGINE CLEANUP - yksinkertainen
  pcall(function() engine.amp(0) end)
  pcall(function() engine.level(0) end)
  
  -- Audio service cleanup (yksinkertaistettu)
  if audio_service then
    pcall(function() audio_service:cleanup() end)
  end
  
  -- Reset state
  state.amp_norm = 0
  state.amp_pulse = 0
  state.pitch_hz = nil
  state.pitch_conf = 0
  state.pitch_midi = nil
  
  -- Turvallinen clock-peruutus
  if analysis_clock then
    pcall(function() clock.cancel(analysis_clock) end)
  end
  if redraw_clock then
    pcall(function() clock.cancel(redraw_clock) end)
  end
  analysis_clock = nil
  redraw_clock = nil
end
