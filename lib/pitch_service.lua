-- Pitch service: 100 ms–grid–normalized current pitch (sample or live) for combining with onsets.
-- Keeps voiced pitch history and commits normalized pitch every grid_ms.

local Mapping = include("lib/mapping")
local musicutil = require "musicutil"

local PitchService = {}
PitchService.__index = PitchService

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function round(v)
  if v >= 0 then return math.floor(v + 0.5) end
  return math.ceil(v - 0.5)
end

local function median(values)
  if #values == 0 then return nil end
  local t = {}
  for i = 1, #values do t[i] = values[i] end
  table.sort(t)
  local c = math.floor(#t / 2)
  if #t % 2 == 1 then return t[c + 1] end
  return (t[c] + t[c + 1]) * 0.5
end

function PitchService.new(opts)
  opts = opts or {}
  local self = setmetatable({}, PitchService)
  self.grid_ms = opts.grid_ms or 100
  self.voiced_cap = opts.voiced_cap or 9
  self.recent_max_age_ms = opts.recent_max_age_ms or 700
  self.voiced_samples = {}
  self.voiced_last_ms = -10000
  self.normalized_pitch_hz = nil
  self.normalized_pitch_midi = nil
  self.normalized_commit_slot = -1
  return self
end

function PitchService:push_voiced(hz, now_ms)
  if not hz or hz <= 0 then return end
  self.voiced_samples[#self.voiced_samples + 1] = hz
  if #self.voiced_samples > self.voiced_cap then
    table.remove(self.voiced_samples, 1)
  end
  self.voiced_last_ms = now_ms
end

function PitchService:recent_voiced(now_ms, max_age_ms)
  local age = max_age_ms or self.recent_max_age_ms
  if #self.voiced_samples == 0 then return nil end
  if (now_ms - self.voiced_last_ms) > age then return nil end
  return median(self.voiced_samples)
end

-- Update normalized pitch every grid_ms. Pass midi_min/midi_max to avoid params dependency.
function PitchService:update(now_ms, raw_pitch_hz, confidence, min_conf, sample_mode, amp_norm, midi_min, midi_max)
  if raw_pitch_hz and raw_pitch_hz > 0 and confidence >= min_conf then
    self:push_voiced(raw_pitch_hz, now_ms)
  end
  local slot = math.floor(now_ms / self.grid_ms)
  if slot <= self.normalized_commit_slot then return end
  self.normalized_commit_slot = slot

  local best_hz = nil
  if raw_pitch_hz and raw_pitch_hz > 0 and confidence >= min_conf then
    best_hz = raw_pitch_hz
  end
  if not best_hz then
    best_hz = self:recent_voiced(now_ms, self.recent_max_age_ms)
  end
  if not best_hz and sample_mode and amp_norm and midi_min and midi_max then
    local amp_midi = midi_min + round(clamp(amp_norm, 0, 1) * (midi_max - midi_min))
    best_hz = musicutil.note_num_to_freq(clamp(amp_midi, midi_min, midi_max))
  end
  if best_hz and best_hz > 0 then
    self.normalized_pitch_hz = best_hz
    self.normalized_pitch_midi = Mapping.hz_to_midi(best_hz)
  end
end

-- Current pitch for combining with an onset (normalized or fallback).
function PitchService:get_current_hz(now_ms)
  if self.normalized_pitch_hz and self.normalized_pitch_hz > 0 then
    return self.normalized_pitch_hz
  end
  local recent = self:recent_voiced(now_ms, self.recent_max_age_ms)
  if recent and recent > 0 then return recent end
  return 220
end

function PitchService:get_state()
  return {
    normalized_pitch_hz = self.normalized_pitch_hz,
    normalized_pitch_midi = self.normalized_pitch_midi,
  }
end

function PitchService:reset()
  self.voiced_samples = {}
  self.voiced_last_ms = -10000
  self.normalized_pitch_hz = nil
  self.normalized_pitch_midi = nil
  self.normalized_commit_slot = -1
end

return PitchService
