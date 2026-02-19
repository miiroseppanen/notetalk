engine.name = "wordpitch_engine"

local fileselect = require "fileselect"
local musicutil = require "musicutil"

local Analyzer = require "lib.analyzer"
local Mapping = require "lib.mapping"
local MidiOut = require "lib.midi_out"

local analyzer
local midi_out

local state = {
  freeze = false,
  sample_loaded = false,
  sample_path = nil,
  source_label = "line in",
  last_event_hz = nil,
  last_event_midi = nil,
  last_event_conf = 0,
  last_event_amp = 0,
  amp_in = 0,
  pitch_hz = nil,
  pitch_conf = 0,
  now_ms = 0,
}

local amp_poll = nil
local pitch_poll = nil
local conf_poll = nil
local analysis_clock = nil
local redraw_clock = nil

local SCALE_NAMES = Mapping.get_scale_names()

local function clamp(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

local function round(value)
  if value >= 0 then
    return math.floor(value + 0.5)
  end
  return math.ceil(value - 0.5)
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

local function current_scale_name()
  local index = params:get("scale")
  return SCALE_NAMES[index] or "chromatic"
end

local function source_is_sample()
  local mode = params:string("input_mode")
  local sample_enabled = params:string("sample_enabled") == "on"
  return mode == "softcut" and sample_enabled and state.sample_loaded
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

local function setup_softcut_defaults()
  pcall(function() softcut.enable(1, 1) end)
  pcall(function() softcut.buffer(1, 1) end)
  pcall(function() softcut.level(1, 1) end)
  pcall(function() softcut.pan(1, 0) end)
  pcall(function() softcut.rate(1, 1) end)
  pcall(function() softcut.loop(1, 1) end)
  pcall(function() softcut.loop_start(1, 0) end)
  pcall(function() softcut.loop_end(1, 4) end)
  pcall(function() softcut.position(1, 0) end)
  pcall(function() softcut.play(1, 0) end)
end

local function load_sample(path)
  if not path or path == "" then
    return
  end

  local ok = pcall(function()
    setup_softcut_defaults()
    softcut.buffer_clear()
    softcut.buffer_read_mono(path, 0, 0, -1, 1, 1, 0)
    softcut.position(1, 0)
    softcut.play(1, 1)
  end)

  if ok then
    state.sample_loaded = true
    state.sample_path = path

    local _, frames, sample_rate = audio.file_info(path)
    if frames and sample_rate and sample_rate > 0 then
      local duration = frames / sample_rate
      pcall(function() softcut.loop_end(1, math.max(0.2, duration)) end)
    end
  end

  update_source_label()
  redraw()
end

local function unload_sample()
  state.sample_loaded = false
  state.sample_path = nil
  pcall(function() softcut.play(1, 0) end)
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

local function trigger_synth(note, amp)
  if params:string("use_synth") ~= "on" then
    return
  end

  local hz = musicutil.note_num_to_freq(note)
  local level = clamp(amp or 0.2, 0, 1)

  pcall(function() engine.hz(hz) end)
  pcall(function() engine.noteOn(level) end)
  clock.run(function()
    clock.sleep(params:get("note_length_ms") / 1000)
    pcall(function() engine.noteOff() end)
  end)
end

local function handle_analysis_event(event)
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

  amp_poll = try_poll("amp_in_l", function(value) state.amp_in = math.abs(value or 0) end)
  pitch_poll = try_poll("pitch_in", function(value) state.pitch_hz = value end)
  conf_poll = try_poll("pitch_conf", function(value) state.pitch_conf = value end)
end

local function cleanup_polls()
  if amp_poll then amp_poll:stop() end
  if pitch_poll then pitch_poll:stop() end
  if conf_poll then conf_poll:stop() end
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
  params:add_option("midi_send", "Send MIDI", {"off", "on"}, 2)
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

local function setup_params()
  params:add_separator("script_sep", "notetalk")
  add_input_params()
  add_analysis_params()
  add_mapping_params()
  add_midi_params()
  add_synth_and_fx_params()
  params:bang()
end

local function analyzer_loop()
  while true do
    clock.sleep(1 / 60)
    state.now_ms = state.now_ms + (1000 / 60)

    if state.freeze then
      goto continue
    end

    update_source_label()

    local amp = clamp(state.amp_in or 0, 0, 1)
    local pitch = state.pitch_hz
    local confidence = clamp(state.pitch_conf or 0, 0, 1)
    local event = analyzer:process_observation(amp, pitch, confidence, state.now_ms)

    if event then
      handle_analysis_event(event)
    end

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
  analyzer = Analyzer.new({
    threshold = 0.05,
    min_conf = 0.45,
    hold_ms = 140,
    window_ms = 120,
  })
  midi_out = MidiOut.new()

  setup_softcut_defaults()
  setup_params()
  setup_polls()
  update_source_label()
  apply_engine_settings()

  analysis_clock = clock.run(analyzer_loop)
  redraw_clock = clock.run(redraw_loop)
  redraw()
end

function enc(n, d)
  if n == 1 then
    params:set("threshold", clamp(params:get("threshold") + d * 0.0025, 0.001, 1))
  elseif n == 2 then
    params:set("min_conf", clamp(params:get("min_conf") + d * 0.01, 0, 1))
  elseif n == 3 then
    local current = params:get("scale")
    local next_index = clamp(current + d, 1, #SCALE_NAMES)
    params:set("scale", next_index)
  end
  redraw()
end

function key(n, z)
  if z == 0 then
    return
  end

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
  if state.last_event_midi then
    screen.text(string.format("last n%d %.2f", state.last_event_midi, state.last_event_conf))
  else
    screen.text("last: none")
  end
  screen.update()
end

function cleanup()
  cleanup_polls()
  if analysis_clock then clock.cancel(analysis_clock) end
  if redraw_clock then clock.cancel(redraw_clock) end
end
