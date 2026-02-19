local Analyzer = {}
Analyzer.__index = Analyzer

local function clamp(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

local function median(values)
  if #values == 0 then
    return nil
  end

  table.sort(values)
  local center = math.floor(#values / 2)
  if #values % 2 == 1 then
    return values[center + 1]
  end

  return (values[center] + values[center + 1]) * 0.5
end

local function envelope_coeff(ms, sample_rate)
  if ms <= 0 then
    return 0
  end
  return math.exp(-1 / (0.001 * ms * sample_rate))
end

function Analyzer.new(opts)
  local options = opts or {}
  local self = setmetatable({}, Analyzer)

  self.sample_rate = options.sample_rate or 48000
  self.highpass_hz = options.highpass_hz or 80
  self.threshold = options.threshold or 0.05
  self.hold_ms = options.hold_ms or 140
  self.window_ms = options.window_ms or 120
  self.min_conf = options.min_conf or 0.45
  self.min_hz = options.min_hz or 65
  self.max_hz = options.max_hz or 1200
  self.pitch_estimate_hop = options.pitch_estimate_hop or 128
  self.pitch_buffer_size = options.pitch_buffer_size or 2048
  self.attack_coeff = envelope_coeff(options.attack_ms or 8, self.sample_rate)
  self.release_coeff = envelope_coeff(options.release_ms or 90, self.sample_rate)

  self.hpf_alpha = self:compute_hpf_alpha(self.highpass_hz)
  self.prev_x = 0
  self.prev_y = 0
  self.env = 0
  self.gate_open = false
  self.last_gate_open_ms = -10000

  self.onset_active = false
  self.onset_started_ms = 0
  self.onset_peak_env = 0
  self.pitch_candidates = {}
  self.conf_candidates = {}

  self.pitch_ring = {}
  self.pitch_ring_pos = 1
  self.pitch_ring_len = 0
  self.hop_counter = 0

  return self
end

function Analyzer:compute_hpf_alpha(cutoff_hz)
  local dt = 1 / self.sample_rate
  local rc = 1 / (2 * math.pi * cutoff_hz)
  return rc / (rc + dt)
end

function Analyzer:set_threshold(value)
  self.threshold = clamp(value, 0, 1)
end

function Analyzer:set_min_conf(value)
  self.min_conf = clamp(value, 0, 1)
end

function Analyzer:set_hold_ms(value)
  self.hold_ms = math.max(1, value)
end

function Analyzer:set_window_ms(value)
  self.window_ms = math.max(20, value)
end

function Analyzer:push_pitch_sample(sample)
  self.pitch_ring[self.pitch_ring_pos] = sample
  self.pitch_ring_pos = self.pitch_ring_pos + 1
  if self.pitch_ring_pos > self.pitch_buffer_size then
    self.pitch_ring_pos = 1
  end
  self.pitch_ring_len = math.min(self.pitch_ring_len + 1, self.pitch_buffer_size)
end

function Analyzer:get_pitch_buffer()
  if self.pitch_ring_len == 0 then
    return {}
  end

  local out = {}
  local start = self.pitch_ring_pos - self.pitch_ring_len
  while start <= 0 do
    start = start + self.pitch_buffer_size
  end

  for i = 0, self.pitch_ring_len - 1 do
    local pos = ((start + i - 1) % self.pitch_buffer_size) + 1
    out[#out + 1] = self.pitch_ring[pos]
  end
  return out
end

function Analyzer:estimate_pitch()
  local buffer = self:get_pitch_buffer()
  local n = #buffer
  if n < 256 then
    return nil, 0
  end

  local lag_min = math.max(2, math.floor(self.sample_rate / self.max_hz))
  local lag_max = math.min(math.floor(self.sample_rate / self.min_hz), math.floor(n / 2))
  if lag_max <= lag_min then
    return nil, 0
  end

  local best_lag = nil
  local best_corr = -1

  for lag = lag_min, lag_max do
    local numerator = 0
    local energy_a = 0
    local energy_b = 0

    for i = 1, n - lag do
      local a = buffer[i]
      local b = buffer[i + lag]
      numerator = numerator + (a * b)
      energy_a = energy_a + (a * a)
      energy_b = energy_b + (b * b)
    end

    local denom = math.sqrt((energy_a * energy_b) + 1e-12)
    local corr = denom > 0 and (numerator / denom) or 0
    if corr > best_corr then
      best_corr = corr
      best_lag = lag
    end
  end

  if not best_lag or best_corr < 0.15 then
    return nil, math.max(0, best_corr)
  end

  local hz = self.sample_rate / best_lag
  return hz, clamp(best_corr, 0, 1)
end

function Analyzer:begin_onset(now_ms)
  self.onset_active = true
  self.onset_started_ms = now_ms
  self.onset_peak_env = self.env
  self.pitch_candidates = {}
  self.conf_candidates = {}
end

function Analyzer:finish_onset()
  self.onset_active = false
  local pitch = median(self.pitch_candidates)
  local confidence = median(self.conf_candidates) or 0
  if pitch == nil or confidence < self.min_conf then
    return nil
  end

  return {
    hz = pitch,
    confidence = confidence,
    amp = self.onset_peak_env,
  }
end

function Analyzer:update_gate(now_ms)
  if (not self.gate_open) and self.env >= self.threshold then
    if (now_ms - self.last_gate_open_ms) >= self.hold_ms then
      self.gate_open = true
      self.last_gate_open_ms = now_ms
      self:begin_onset(now_ms)
    end
  elseif self.gate_open and self.env < (self.threshold * 0.7) then
    self.gate_open = false
  end
end

function Analyzer:process_sample(sample, now_ms)
  local y = self.hpf_alpha * (self.prev_y + sample - self.prev_x)
  self.prev_x = sample
  self.prev_y = y

  local level = math.abs(y)
  if level > self.env then
    self.env = self.attack_coeff * self.env + (1 - self.attack_coeff) * level
  else
    self.env = self.release_coeff * self.env + (1 - self.release_coeff) * level
  end

  self:push_pitch_sample(y)
  self:update_gate(now_ms)

  if self.onset_active then
    self.onset_peak_env = math.max(self.onset_peak_env, self.env)
    self.hop_counter = self.hop_counter + 1
    if self.hop_counter >= self.pitch_estimate_hop then
      self.hop_counter = 0
      local hz, confidence = self:estimate_pitch()
      if hz and confidence > 0 then
        self.pitch_candidates[#self.pitch_candidates + 1] = hz
        self.conf_candidates[#self.conf_candidates + 1] = confidence
      end
    end

    if (now_ms - self.onset_started_ms) >= self.window_ms then
      return self:finish_onset()
    end
  end

  return nil
end

function Analyzer:process_block(samples, now_ms_start)
  local events = {}
  local now_ms = now_ms_start
  local ms_per_sample = 1000 / self.sample_rate

  for _, sample in ipairs(samples) do
    local event = self:process_sample(sample, now_ms)
    if event then
      events[#events + 1] = event
    end
    now_ms = now_ms + ms_per_sample
  end

  return events
end

function Analyzer:process_observation(amp, hz, confidence, now_ms)
  self.env = self.release_coeff * self.env + (1 - self.release_coeff) * clamp(amp or 0, 0, 1)
  self:update_gate(now_ms)

  if self.onset_active then
    self.onset_peak_env = math.max(self.onset_peak_env, self.env)
    if hz and hz > 0 then
      self.pitch_candidates[#self.pitch_candidates + 1] = hz
      self.conf_candidates[#self.conf_candidates + 1] = clamp(confidence or 0, 0, 1)
    end

    if (now_ms - self.onset_started_ms) >= self.window_ms then
      return self:finish_onset()
    end
  end

  return nil
end

return Analyzer
