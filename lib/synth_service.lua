-- Synth service: Norns engine trigger, levels, deferred init, boot tone, cleanup.
-- Uses state.synth_engine; opts: state, params, defer_clock_fn, set_engine_cut_level(level).

local musicutil = require "musicutil"

local SynthService = {}
SynthService.__index = SynthService

local function clamp(value, min_val, max_val)
  return math.max(min_val, math.min(max_val, value))
end

-- Notetalk ensin (cut-bus amp_cut/pitch_cut pollit); PolyPerc fallback
local ENGINES_TO_TRY = {"Notetalk", "PolyPerc", "TestSine", "SimplePassThru"}

function SynthService.new(opts)
  local self = setmetatable({}, SynthService)
  self.state = opts.state
  self.params = opts.params
  self.defer_clock_fn = opts.defer_clock_fn
  self.set_engine_cut_level = opts.set_engine_cut_level or function() end
  return self
end

function SynthService:add_params()
  local params = self.params
  params:add_separator("synth_sep", "Synth and FX")
  params:add_option("use_synth", "Use Synth", {"off", "on"}, 2)
  params:set_action("use_synth", function() self:apply_settings() end)

  params:add_control("synth_level", "Synth Level", controlspec.new(0, 1, "lin", 0, 1.0, ""))
  params:set_action("synth_level", function() self:apply_settings() end)

  params:add_control("fx_reverb_send", "FX Reverb Send", controlspec.new(0, 1, "lin", 0, 0.2, ""))
  params:set_action("fx_reverb_send", function() self:apply_settings() end)

  params:add_control("fx_delay_send", "FX Delay Send", controlspec.new(0, 1, "lin", 0, 0.1, ""))
  params:set_action("fx_delay_send", function() self:apply_settings() end)
end

function SynthService:apply_settings()
  local synth_on = self.params:string("use_synth") == "on"
  local synth_level = self.params:get("synth_level")
  local reverb_send = self.params:get("fx_reverb_send")
  local delay_send = self.params:get("fx_delay_send")
  local target_level = synth_on and synth_level or 0

  self.set_engine_cut_level(target_level)

  local eng = self.state.synth_engine
  if eng and eng.level then
    pcall(eng.level, target_level)
  elseif pcall(function() return engine.level ~= nil end) then
    pcall(function() engine.level(target_level) end)
  end
  if eng and eng.amp then
    pcall(eng.amp, target_level)
  elseif pcall(function() return engine.amp ~= nil end) then
    pcall(function() engine.amp(target_level) end)
  end
  if pcall(function() return engine.reverb_send ~= nil end) then
    pcall(function() engine.reverb_send(reverb_send) end)
  end
  if pcall(function() return engine.delay_send ~= nil end) then
    pcall(function() engine.delay_send(delay_send) end)
  end
end

-- Test tone: always play 440 Hz for ~0.2 s to verify engine and audio path (ignore use_synth).
function SynthService:play_test_tone()
  self.set_engine_cut_level(1.0)
  local hz = 440
  local level = 0.5
  -- Aina suoraan engine.* (ei riipu state.synth_engine)
  pcall(function() if engine.release then engine.release(0.2) end end)
  pcall(function() if engine.level then engine.level(level) end end)
  pcall(function() if engine.amp then engine.amp(level) end end)
  pcall(function() if engine.hz then engine.hz(hz) elseif engine.freq then engine.freq(hz) end end)
  local state = self.state
  if not state.synth_engine then
    local h = (type(engine.hz) == "function") and engine.hz or (type(engine.freq) == "function") and engine.freq or nil
    local a = (type(engine.amp) == "function") and engine.amp or nil
    local l = (type(engine.level) == "function") and engine.level or nil
    if (h or a or l) then
      state.synth_engine = {
        hz = h,
        amp = a,
        level = l,
        noteOn = (type(engine.noteOn) == "function") and engine.noteOn or nil,
        noteOff = (type(engine.noteOff) == "function") and engine.noteOff or nil,
      }
    end
  end
  if self.defer_clock_fn then
    self.defer_clock_fn(function()
      clock.sleep(0.25)
      pcall(function() if engine.amp then engine.amp(0) end end)
      pcall(function() if engine.level then engine.level(0) end end)
    end)
  end
  print("notetalk: test tone 440 Hz")
end

function SynthService:trigger_note(note, amp)
  if self.params:string("use_synth") ~= "on" then
    return
  end

  local synth_level = self.params:get("synth_level")
  self:apply_settings()
  self.set_engine_cut_level(synth_level)

  local hz = musicutil.note_num_to_freq(note)
  local amp_norm = clamp(amp or 0.2, 0, 1)
  local level = clamp(0.5 + (amp_norm * 0.5), 0, 1) * synth_level
  level = clamp(level, 0, 1)

  local state = self.state
  -- Uudelleentunnista moottori jokaisella triggerillä (myöhässä latautunut / Shield)
  if not state.synth_engine then
    local h = (type(engine.hz) == "function") and engine.hz or nil
    local f = (type(engine.freq) == "function") and engine.freq or nil
    local a = (type(engine.amp) == "function") and engine.amp or nil
    local l = (type(engine.level) == "function") and engine.level or nil
    local no = (type(engine.noteOn) == "function") and engine.noteOn or nil
    local nf = (type(engine.noteOff) == "function") and engine.noteOff or nil
    if (h or f) and (a or l) then
      state.synth_engine = { hz = h or f, amp = a, level = l, noteOn = no, noteOff = nf }
    elseif no then
      state.synth_engine = { hz = h or f, amp = a, level = l, noteOn = no, noteOff = nf }
    end
  end
  local eng = state.synth_engine
  if eng then
    if eng.level then pcall(eng.level, level) elseif engine.level then pcall(function() engine.level(level) end) end
    if eng.amp then pcall(eng.amp, level) elseif engine.amp then pcall(function() engine.amp(level) end) end
    if eng.hz then pcall(eng.hz, hz) elseif engine.hz then pcall(function() engine.hz(hz) end)
    elseif engine.freq then pcall(function() engine.freq(hz) end) end
  else
    pcall(function() if engine.level then engine.level(level) end end)
    pcall(function() if engine.amp then engine.amp(level) end end)
    if engine.hz then pcall(function() engine.hz(hz) end)
    elseif engine.freq then pcall(function() engine.freq(hz) end) end
    if engine.note_num then pcall(function() engine.note_num(note) end) end
  end

  local ok_note_on = false
  if eng and eng.noteOn and type(eng.noteOn) == "function" then
    ok_note_on = pcall(eng.noteOn, level)
  end
  if not ok_note_on and engine.noteOn then
    ok_note_on = pcall(function() engine.noteOn(level) end)
  end
  if not ok_note_on and (engine.freq or engine.hz) then
    ok_note_on = pcall(function() if engine.freq then engine.freq(hz) elseif engine.hz then engine.hz(hz) end end)
  end
  if not eng and not ok_note_on then
    print("notetalk: SYNTH no engine (K3 or trigger: try loading script again or check engine)")
  end
  if ok_note_on and self.defer_clock_fn then
    local note_length_ms = self.params:get("note_length_ms")
    self.defer_clock_fn(function()
      clock.sleep(note_length_ms / 1000)
      if state.freeze then return end
      local e = state.synth_engine
      if e and e.noteOff and type(e.noteOff) == "function" then
        pcall(e.noteOff)
      else
        pcall(function() engine.noteOff() end)
      end
    end)
  end
end

function SynthService:init_engine(on_engine_ready)
  local state = self.state
  local defer_clock = self.defer_clock_fn

  local function try_engine(name)
    local ok = pcall(function() engine.name = name end)
    if not ok then return false end
    clock.sleep(1.5)
    local name_ok, current_name = pcall(function() return engine.name end)
    if not name_ok or current_name ~= name then return false end

    for _ = 1, 3 do
      local hz_ok = type(engine.hz) == "function"
      local freq_ok = type(engine.freq) == "function"
      local amp_ok = type(engine.amp) == "function"
      if (hz_ok or freq_ok) and (amp_ok or type(engine.level) == "function") then break end
      clock.sleep(0.8)
    end
    local has_hz = pcall(function() return engine.hz ~= nil end)
    local has_freq = pcall(function() return engine.freq ~= nil end)
    local has_amp = pcall(function() return engine.amp ~= nil end)
    local has_level = pcall(function() return engine.level ~= nil end)
    local has_noteOn = pcall(function() return engine.noteOn ~= nil end)
    if not (has_hz or has_freq or has_amp or has_level or has_noteOn) then return false end

    state.synth_engine = {
      hz = (type(engine.hz) == "function") and engine.hz or (type(engine.freq) == "function") and engine.freq or nil,
      amp = (type(engine.amp) == "function") and engine.amp or nil,
      level = (type(engine.level) == "function") and engine.level or nil,
      noteOn = (type(engine.noteOn) == "function") and engine.noteOn or nil,
      noteOff = (type(engine.noteOff) == "function") and engine.noteOff or nil,
    }
    local eng = state.synth_engine
    if eng.hz and (eng.amp or eng.level) then
      local ok_hz, err_hz = pcall(eng.hz, 440)
      local ok_amp = true
      if eng.amp then ok_amp = pcall(eng.amp, 0.35) end
      if not ok_hz or not ok_amp then
        print("notetalk: SYNTH ref test failed - hz:" .. tostring(err_hz))
        state.synth_engine = nil
        return false
      end
    end
    local noteOn_fn = engine.noteOn
    local noteOff_fn = engine.noteOff
    local hz_fn = state.synth_engine.hz
    local amp_fn = engine.amp
    local boot_played = false

    if noteOn_fn and type(noteOn_fn) == "function" then
      local ok_note = pcall(function() noteOn_fn(0.35) end)
      if ok_note then
        defer_clock(function()
          clock.sleep(0.2)
          if state.freeze then return end
          if noteOff_fn and type(noteOff_fn) == "function" then
            pcall(noteOff_fn)
          else
            pcall(function() engine.noteOff() end)
          end
        end)
        boot_played = true
      end
    end
    if not boot_played and hz_fn and type(hz_fn) == "function" then
      local ok_hz = pcall(function() hz_fn(440) end)
      local ok_amp = true
      if type(amp_fn) == "function" then
        ok_amp = pcall(function() amp_fn(0.35) end)
      elseif type(engine.level) == "function" then
        ok_amp = pcall(function() engine.level(0.35) end)
      end
      if ok_hz and ok_amp then
        defer_clock(function()
          clock.sleep(0.2)
          if state.freeze then return end
          if type(amp_fn) == "function" then pcall(amp_fn, 0)
          elseif type(engine.level) == "function" then pcall(engine.level, 0) end
        end)
        boot_played = true
      end
    end
    return true
  end

  defer_clock(function()
    clock.sleep(2.0)
    if state.freeze then return end
    local engine_loaded = false
    for _, engine_name in ipairs(ENGINES_TO_TRY) do
      if try_engine(engine_name) then
        engine_loaded = true
        local eng_cut = self.params:string("use_synth") == "on" and self.params:get("synth_level") or 0
        self:apply_settings()
        self.set_engine_cut_level(eng_cut)
        print("notetalk: SYNTH engine loaded eng_cut=" .. string.format("%.2f", eng_cut))
        break
      end
      clock.sleep(0.5)
    end
    if not engine_loaded then
      print("notetalk: SYNTH no engine loaded. Current engine commands:")
      pcall(function() engine.list_commands() end)
    end
    if on_engine_ready then on_engine_ready(engine_loaded) end
  end)
end

function SynthService:cleanup()
  local eng = self.state.synth_engine
  if eng and eng.amp then pcall(eng.amp, 0) else pcall(function() engine.amp(0) end) end
  if eng and eng.level then pcall(eng.level, 0) else pcall(function() engine.level(0) end) end
end

return SynthService
