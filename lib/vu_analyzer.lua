-- VU analyzer: level normalization (sample mode), amp_norm, amp_for_vu, vu_level.
-- Writes to state: amp_floor_est, amp_ceil_est, amp_pulse (decay), amp_norm, amp_for_vu, vu_level.
-- Returns normalized (or raw) amp for use by pitch/onset.

local VUAnalyzer = {}
VUAnalyzer.__index = VUAnalyzer

local function clamp(value, min_val, max_val)
  return math.max(min_val, math.min(max_val, value))
end

function VUAnalyzer.new(opts)
  local self = setmetatable({}, VUAnalyzer)
  self.state = opts.state
  self.vu_decay = opts.vu_decay or 0.96
  self.amp_for_vu_alpha = opts.amp_for_vu_alpha or 0.28
  self.vu_gain = opts.vu_gain or 15
  return self
end

-- Update normalization (sample mode), VU state, and amp_pulse decay.
-- opts: amp_raw, sample_mode. Caller sets state.amp_pulse = max(state.amp_pulse, trigger_amp) on onset.
-- Writes to state: amp_floor_est, amp_ceil_est, amp_pulse, amp_norm, amp_for_vu, vu_level.
-- Returns: amp (normalized in sample mode, else amp_raw) for trigger/display use.
function VUAnalyzer:update(opts)
  local state = self.state
  local amp_raw = opts.amp_raw or 0
  local sample_mode = opts.sample_mode or false

  local amp = clamp(amp_raw, 0, 1)
  local min_floor = 0.0001
  local max_ceil_ratio = 50.0

  if sample_mode then
    state.amp_floor_est = math.max(min_floor,
      (state.amp_floor_est * 0.995) + (amp_raw * 0.005))
    if amp_raw > state.amp_ceil_est then
      state.amp_ceil_est = amp_raw
    else
      state.amp_ceil_est = math.max(
        state.amp_floor_est * 2.0,
        state.amp_ceil_est * 0.9995
      )
    end
    if state.amp_ceil_est > (state.amp_floor_est * max_ceil_ratio) then
      state.amp_ceil_est = state.amp_floor_est * max_ceil_ratio
    end
    local span = math.max(0.01, state.amp_ceil_est - state.amp_floor_est)
    amp = clamp((amp_raw - state.amp_floor_est) / span, 0, 1)
  end

  state.amp_pulse = (state.amp_pulse or 0) * (sample_mode and 0.97 or 0.9)
  state.amp_norm = math.max(amp, state.amp_pulse)
  state.amp_for_vu = 0.88 * (state.amp_for_vu or 0) + self.amp_for_vu_alpha * amp

  local vu_raw = 0
  if sample_mode then
    vu_raw = math.max(state.amp_out_l or 0, state.amp_out_r or 0)
  else
    vu_raw = math.max(state.amp_in_l or 0, state.amp_in_r or 0)
  end
  local vu_scaled = math.min(1, vu_raw * self.vu_gain)
  local instant = math.max(vu_scaled, state.amp_norm or 0)
  state.vu_level = math.max(instant, (state.vu_level or 0) * self.vu_decay)

  return amp
end

return VUAnalyzer
