-- Onset service: hit detection only (sample or live). No pitch; combine with pitch service for notes.

local OnsetService = {}
OnsetService.__index = OnsetService

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

-- One-shot detection. Returns: onset_accept, trigger_amp, effective_threshold.
-- last_trigger_ms is held by caller and updated when onset_accept is true.
function OnsetService.detect(opts)
  local now_ms = opts.now_ms
  local amp_trigger_metric = opts.amp_trigger_metric
  local previous_amp = opts.previous_amp
  local last_trigger_ms = opts.last_trigger_ms or -10000
  local threshold = opts.threshold or 0.05
  local hold_ms = opts.hold_ms or 140
  local sample_mode = opts.sample_mode or false
  local amp_floor_est = opts.amp_floor_est or 0
  local amp_ceil_est = opts.amp_ceil_est or 0.1

  local effective_threshold = threshold
  if sample_mode then
    local min_threshold = math.max(0.001, amp_floor_est * 1.2)
    local max_threshold = math.min(0.15, amp_ceil_est * 0.35)
    effective_threshold = clamp(threshold, min_threshold, max_threshold)
    if amp_ceil_est > amp_floor_est then
      local norm_threshold = (effective_threshold - amp_floor_est) / (amp_ceil_est - amp_floor_est)
      norm_threshold = clamp(norm_threshold, 0.05, 0.8)
    end
  end

  local amp_delta = amp_trigger_metric - previous_amp
  local onset_candidate = amp_trigger_metric >= effective_threshold
  local onset_rise_ok = amp_delta >= 0.002
  local refractory_ok = (now_ms - last_trigger_ms) >= hold_ms
  local onset_accept = onset_candidate and onset_rise_ok and refractory_ok

  local trigger_amp = 0
  if onset_accept then
    trigger_amp = clamp(math.max(amp_trigger_metric, effective_threshold * 1.2), 0, 1)
  end

  return onset_accept, trigger_amp, effective_threshold
end

return OnsetService
