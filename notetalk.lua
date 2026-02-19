-- notetalk
-- Speek to notes
-- Kantama
-- v1.0.0 @2026
--  

-- Engine: set in deferred init so script has sound on shields with no default engine.
-- (Setting at load time can corrupt JACK on some systems.)

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
local AudioService = include("lib/audio_service")
local AudioInput = include("lib/audio_input")
local AudioOutput = include("lib/audio_output")
local VUAnalyzer = include("lib/vu_analyzer")
local SynthService = include("lib/synth_service")
local GridController = include("lib/grid_controller")
local PitchService = include("lib/pitch_service")
local OnsetService = include("lib/onset_service")

local analyzer
local midi_out
local grid_controller = nil
local audio_service
local audio_input
local audio_output
local vu_analyzer
local synth_service
local pitch_service

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
  amp_for_vu = 0,  -- jatkuva taso ilman trigger-pulssia, jotta VU = volume eikä "viimeisin isku"
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
  vu_level = 0,  -- VU-mittarille: hitaasti decaytaava taso (ulos/sisääntulo)
  vu_test_mode = false,  -- Oletuksena pois: grid näyttää oikean äänen tason
  grid_col_amp = {},   -- per-sarake: kohdetaso (decay)
  grid_col_display = {}, -- per-sarake: näytetty taso (smooth rise)
  -- Norns engine can return nil on later lookup; store refs when engine loads (see init).
  synth_engine = nil,  -- { hz, amp, level, noteOn, noteOff } when loaded
  engine_ready = false,  -- true after init_engine has loaded and verified engine (K3 test waits for this)
  -- Softcut-mode analysis from SC (cut bus): filled when SC engine sends amp_cut, pitch_cut, pitch_cut_conf
  amp_sc = nil,
  pitch_sc = nil,
  pitch_sc_conf = nil,
}

local analysis_clock = nil
local redraw_clock = nil

local g = nil
local grid_cols = 0
local grid_rows = 0
-- g/grid_cols/grid_rows synkataan grid_controllerista setupin jälkeen
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
  local poll_status = audio_input and {
    amp_poll = true,
    amp_poll_aux = true,
    amp_poll_in_l = true,
    amp_poll_in_r = true,
    pitch_poll = true,
    conf_poll = true,
  } or {}
  
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
  if grid_controller then
    return grid_controller:is_ready()
  end
  return g ~= nil and grid_cols > 0 and grid_rows > 0
end

local function update_source_label()
  if source_is_sample() then
    state.source_label = "sample"
  else
    state.source_label = "line in"
  end
end

-- Normalize sample path to full path (works when fileselect or device returns different formats)
local function normalize_sample_path(path)
  if not path or path == "" then return path end
  path = path:gsub("^%s+", ""):gsub("%s+$", "")
  if path:sub(1, 1) == "/" then
    return path
  end
  local base = _path.audio and (_path.audio:gsub("/$", "")) or "/home/we/dust/audio"
  return base .. "/" .. path:gsub("^/", "")
end

-- Moved to AudioService

local function load_sample(path, attempt)
  if not path or path == "" then
    return
  end
  path = normalize_sample_path(path)
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
  local hz = (pitch_service and pitch_service:recent_voiced(now_ms, 700)) or event_hz
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

  -- Debug: varmista matron-lokissa että trigger tapahtui (näkyy Maidenissa)
  print("notetalk: TRIGGER note=" .. tostring(note) .. " hz=" .. string.format("%.1f", event.hz) .. " amp=" .. string.format("%.2f", event.amp or 0))

  if midi_out then
    pcall(function()
          midi_out:set_note_length_ms(params:get("note_length_ms"))
          midi_out:trigger_note(note, event.amp)
    end)
  end
  if synth_service then
    synth_service:trigger_note(note, event.amp)
  end
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
  if audio_input then
    audio_input:setup()
  end
end

local function cleanup_polls()
  if audio_input then
    audio_input:cleanup()
  end
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

  params:add_control("sample_level", "Sample Level", controlspec.new(0, 1, "lin", 0, 0.5, ""))
  params:set_action("sample_level", function(value)
    pcall(function() softcut.level(1, value) end)
  end)
end

local function add_analysis_params()
  params:add_separator("analysis_sep", "Analysis")
  params:add_control("threshold", "Threshold", controlspec.new(0.001, 1, "lin", 0, 0.01, ""))
  params:set_action("threshold", function(value)
    analyzer:set_threshold(value)
  end)

  params:add_control("min_conf", "Min Confidence", controlspec.new(0, 1, "lin", 0, 0.35, ""))
  params:set_action("min_conf", function(value)
    analyzer:set_min_conf(value)
  end)

  params:add_number("hold_ms", "Gate Hold (ms)", 10, 1000, 140)
  params:set_action("hold_ms", function(value)
    analyzer:set_hold_ms(value)
  end)

  params:add_number("onset_debounce_ms", "Onset Debounce (ms)", 80, 150, 100)
  params:add_number("timing_offset_ms", "Timing Offset (ms)", -100, 200, 60)

  params:add_number("window_ms", "Pitch Window (ms)", 20, 800, 120)
  params:set_action("window_ms", function(value)
    analyzer:set_window_ms(value)
  end)
end

local function add_mapping_params()
  params:add_separator("mapping_sep", "Mapping")
  params:add_number("bpm", "BPM (0=off)", 0, 240, 0)
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

local function setup_params()
  params:add_separator("script_sep", "notetalk")
  add_input_params()
  add_analysis_params()
  add_mapping_params()
  add_midi_params()
  if synth_service then
    synth_service:add_params()
  end
  if grid_controller then
    grid_controller:add_params()
  end
  params:add_option("vu_debug_screen", "VU Debug (screen)", {"off", "on"}, 1)
  params:bang()
end

local function setup_debug_sample_defaults()
  local base = (_path.audio and _path.audio:gsub("/$", "")) or "/home/we/dust/audio"
  local rel = DEBUG_SAMPLE_RELATIVE_PATH:gsub("^/", "")
  -- Try lowercase first (kantama), then Kantama (case can differ per device)
  local debug_path = base .. "/" .. rel
  local info_ok, _ = pcall(audio.file_info, debug_path)
  if not info_ok then
    local alt = base .. "/" .. rel:gsub("^kantama", "Kantama")
    if alt ~= debug_path then
      info_ok, _ = pcall(audio.file_info, alt)
      if info_ok then debug_path = alt end
    end
  end
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
  params:set("sample_level", 0.5)
  params:set("synth_level", 1.0)
  load_sample(debug_path)
end

local function schedule_debug_sample_defaults()
  defer_clock(function()
    -- Delay so audio/softcut and engine are ready before loading sample at boot.
    clock.sleep(1.2)
    if state.freeze then
      return
    end
    setup_debug_sample_defaults()
  end)
end

set_active_line_from_event = function(_event)
  -- Grid line effects can be added here or in grid_visualizer
end

local function setup_grid()
  if not grid_controller then return end
  grid_controller:setup()
  g = grid_controller.g
  grid_cols = grid_controller.grid_cols
  grid_rows = grid_controller.grid_rows
end

local function analyzer_loop()
  local previous_amp = 0
  local poll_check_counter = 0
  local ANALYZER_HZ = 100  -- poll rate for analysis (spec: 100 Hz)
  local now_inc_ms = 1000 / ANALYZER_HZ

  while true do
    clock.sleep(1 / ANALYZER_HZ)
    state.now_ms = state.now_ms + now_inc_ms
    state.onset_event = false

    if state.freeze then
      goto continue
    end

    poll_check_counter = poll_check_counter + 1
    if poll_check_counter >= ANALYZER_HZ then
      poll_check_counter = 0
      if audio_input then
        audio_input:ensure_healthy({
          now_ms = state.now_ms,
          source_is_sample = source_is_sample,
          audio_service = audio_service,
          debug_log = debug_log,
          debug_should_log = debug_should_log,
        })
      end
    end

    update_source_label()

    local sample_mode = source_is_sample()
    local analysis_source_softcut = (params:string("input_mode") == "softcut")
    local amp_raw = 0
    local raw_pitch_hz_override = nil
    local confidence_override = nil

    if analysis_source_softcut then
      -- Softcut mode: analysis from cut bus (SC engine). Do NOT use ADC.
      amp_raw = state.amp_sc or 0
      raw_pitch_hz_override = state.pitch_sc
      confidence_override = state.pitch_sc_conf
      if state.sample_loaded and audio_service then
        audio_service:ensure_monitor_routing()
      end
    else
      -- Audio-in mode: analysis from ADC
      local amp_in = math.max(state.amp_in_l or 0, state.amp_in_r or 0)
      local amp_out = math.max(state.amp_out_l or 0, state.amp_out_r or 0)
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
      })
    end

    -- VU: use analysis source amplitude for display when softcut (cut-bus level, not ADC)
    local amp_for_vu_override = analysis_source_softcut and (state.amp_sc or 0) or nil
    local amp = vu_analyzer and vu_analyzer:update({
      amp_raw = amp_raw,
      sample_mode = sample_mode,
      amp_for_vu_override = amp_for_vu_override,
    }) or clamp(amp_raw, 0, 1)

    local raw_pitch_hz = (analysis_source_softcut and raw_pitch_hz_override ~= nil) and raw_pitch_hz_override or state.pitch_hz
    local confidence = (analysis_source_softcut and confidence_override ~= nil) and clamp(confidence_override, 0, 1) or clamp(state.pitch_conf or 0, 0, 1)
    local min_conf = params:get("min_conf")

    -- Pitch service: 100 ms–grid–normalized pitch (sample or live); always in state for combining with onsets
    if pitch_service then
      pitch_service:update(state.now_ms, raw_pitch_hz, confidence, min_conf, sample_mode, amp, params:get("midi_min"), params:get("midi_max"))
    end

    local amp_trigger_metric = amp_raw  -- Always use raw signal for trigger detection

    -- Display: 100 ms–normalized pitch when available (pitch service), else raw
    if pitch_service then
      local ps = pitch_service:get_state()
      state.pitch_midi = ps.normalized_pitch_midi or current_pitch_midi()
    else
      state.pitch_midi = current_pitch_midi()
    end

    local debounce_ms = math.max(params:get("hold_ms") or 140, params:get("onset_debounce_ms") or 100)
    local onset_accept, trigger_amp, effective_threshold = OnsetService.detect({
      now_ms = state.now_ms,
      amp_trigger_metric = amp_trigger_metric,
      previous_amp = previous_amp,
      last_trigger_ms = state.debug_last_trigger_ms,
      threshold = params:get("threshold"),
      hold_ms = params:get("hold_ms"),
      debounce_ms = debounce_ms,
      sample_mode = sample_mode,
      amp_floor_est = state.amp_floor_est,
      amp_ceil_est = state.amp_ceil_est,
    })
    if onset_accept then
      state.debug_hit_count = state.debug_hit_count + 1
      state.debug_last_trigger_ms = state.now_ms
      state.amp_pulse = math.max(state.amp_pulse, trigger_amp)
      local timing_offset_ms = params:get("timing_offset_ms") or 0
      local onset_time_corrected_ms = state.now_ms - timing_offset_ms
      local hz = pitch_service and pitch_service:get_current_hz(state.now_ms) or 220
      handle_analysis_event({
        hz = hz,
        confidence = 1,
        amp = trigger_amp,
        onset_time_corrected_ms = onset_time_corrected_ms,
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
        pitch_hz = (pitch_service and (pitch_service:get_state()).normalized_pitch_hz) or raw_pitch_hz or -1,
        conf = confidence,
        hit_count = state.debug_hit_count,
        sample_mode = sample_mode,
        input_mode = params:string("input_mode"),
        sample_enabled = params:string("sample_enabled"),
        sample_loaded = state.sample_loaded,
        threshold = effective_threshold,
        threshold_user = params:get("threshold"),
      })
      -- #endregion
    end
    
    previous_amp = amp_trigger_metric

    local obs_pitch = (pitch_service and (pitch_service:get_state()).normalized_pitch_hz) or raw_pitch_hz
    analyzer:process_observation(amp, obs_pitch, confidence, state.now_ms)

    ::continue::
  end
end

local function redraw_loop()
  while true do
    clock.sleep(1 / 20)  -- 20 fps, spec
    redraw()
  end
end

function init()
  -- Notetalk ensin (cut-bus pollit); synth_service kokeilee PolyPerc fallback
  pcall(function() engine.name = "Notetalk" end)
  if analysis_clock then
    pcall(function() clock.cancel(analysis_clock) end)
    analysis_clock = nil
  end
  if redraw_clock then
    pcall(function() clock.cancel(redraw_clock) end)
    redraw_clock = nil
  end

  analyzer = Analyzer.new({
    threshold = 0.02,
    min_conf = 0.35,
    hold_ms = 140,
    window_ms = 120,
  })
  pitch_service = PitchService.new({ grid_ms = 100 })
  midi_out = MidiOut.new()
  audio_service = AudioService.new()
  audio_output = AudioOutput.new()
  audio_input = AudioInput.new({ state = state })
  vu_analyzer = VUAnalyzer.new({ state = state })
  grid_controller = GridController.new({
    state = state,
    params = params,
    source_is_sample = source_is_sample,
    option_index = option_index,
    connect_grid = function() return grid.connect(1) end,
    grid_module = grid,
  })
  synth_service = SynthService.new({
    state = state,
    params = params,
    defer_clock_fn = defer_clock,
    set_engine_cut_level = function(level)
      if audio_output then audio_output:set_engine_cut_level(level) end
    end,
  })

  audio_output:setup()
  audio_service:setup_defaults()
  setup_params()
  state.vu_test_mode = (params:get("vu_test_mode") == 2)
  setup_polls()
  setup_grid()

  if ENABLE_DEBUG_AUTOSAMPLE then
    schedule_debug_sample_defaults()
  end
  update_source_label()
  if synth_service then synth_service:apply_settings() end

  synth_service:init_engine(function(engine_loaded)
    if engine_loaded then
      state.engine_ready = true
    end
    -- Käynnistä analyzer aina jotta VU/grid ja onset-toiminta päivittyvät (nuotit soi kun moottori on)
    if not analysis_clock then
      analysis_clock = clock.run(analyzer_loop)
    end
    redraw()
  end)

  redraw_clock = clock.run(redraw_loop)
  redraw()

  defer_clock(function()
    clock.sleep(0.1)
    if state.freeze then return end
    local sl = 0.8
    if params and params.get then
      local ok, v = pcall(function() return params:get("sample_level") end)
      if ok and v then sl = v end
    end
    pcall(function() softcut.level(1, sl) end)
  end)
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
    local eng = state.synth_engine
    if eng and eng.amp then pcall(eng.amp, target_level) else pcall(function() engine.amp(target_level) end) end
    if eng and eng.level then pcall(eng.level, target_level) else pcall(function() engine.level(target_level) end) end
  end
  redraw()
end

function key(n, z)
  if z == 1 then
    if n == 2 then
      state.freeze = not state.freeze
    elseif n == 3 then
      -- K3: pakota äänitie auki, sitten testitoni ja note event
      if audio_output then
        audio_output:set_engine_cut_level(1.0)
      end
      pcall(function() audio.level_dac(1.0) end)
      pcall(function() audio.level_cut(1.0) end)
      pcall(function() audio.level_eng_cut(1.0) end)
      pcall(function() audio.level_eng(1.0) end)
      if synth_service then
        synth_service:play_test_tone()
      end
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
  screen.text(string.format("%s h:%d synth:%s", last_text, state.debug_hit_count, params:string("use_synth")))

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

  -- VU debug: näytä datat jotka syöttävät grid-visun (selvitetään synkkaongelmaa)
  if params:get("vu_debug_screen") == 2 then
    local an = state.amp_norm or 0
    local av = state.amp_for_vu or 0
    local vl = state.vu_level or 0
    local out = math.max(state.amp_out_l or 0, state.amp_out_r or 0)
    local inp = math.max(state.amp_in_l or 0, state.amp_in_r or 0)
    screen.level(12)
    screen.move(0, 52)
    screen.text(string.format("VU an:%.2f av:%.2f vl:%.2f o:%.2f i:%.2f", an, av, vl, out, inp))
    local p = state.normalized_pitch_midi or state.pitch_midi
    local d1 = state.grid_col_display and state.grid_col_display[1] or 0
    local d8 = state.grid_col_display and state.grid_col_display[8] or 0
    screen.move(0, 60)
    screen.text(string.format("pitch:%s d1:%.2f d8:%.2f src:%s", p and tostring(round(p)) or "-", d1, d8, state.source_label))
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
  if grid_controller then
    pcall(function() grid_controller:stop() end)
  end
  g = nil
  grid_cols = 0
  grid_rows = 0
  if synth_service then
    pcall(function() synth_service:cleanup() end)
  end
  if audio_output then
    pcall(function() audio_output:cleanup() end)
  end
  if audio_service then
    pcall(function() audio_service:cleanup() end)
  end
  
  -- Reset state
  state.amp_norm = 0
  state.amp_pulse = 0
  state.amp_for_vu = 0
  state.pitch_hz = nil
  state.pitch_conf = 0
  state.pitch_midi = nil
  if pitch_service then pitch_service:reset() end
  
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
