-- Audio input: amp and pitch polls, health check and restart.
-- Writes to state: amp_out_l, amp_out_r, amp_in_l, amp_in_r, pitch_hz, pitch_conf.

local AudioInput = {}
AudioInput.__index = AudioInput

local PITCH_POLL_NAMES = {"pitch_in", "pitch_out", "pitch", "in_pitch"}
local CONF_POLL_NAMES = {"pitch_conf", "pitch_out_conf", "conf", "pitch_confidence", "in_pitch_conf"}

function AudioInput.new(opts)
  local self = setmetatable({}, AudioInput)
  self.state = opts.state
  self.amp_poll = nil
  self.amp_poll_aux = nil
  self.amp_poll_in_l = nil
  self.amp_poll_in_r = nil
  self.pitch_poll = nil
  self.conf_poll = nil
  self.pitch_retry_metro = nil
  return self
end

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

function AudioInput:setup()
  local state = self.state
  self.amp_poll = try_poll("amp_out_l", function(value) state.amp_out_l = math.abs(value or 0) end)
  self.amp_poll_aux = try_poll("amp_out_r", function(value) state.amp_out_r = math.abs(value or 0) end)
  self.amp_poll_in_l = try_poll("amp_in_l", function(value) state.amp_in_l = math.abs(value or 0) end)
  self.amp_poll_in_r = try_poll("amp_in_r", function(value) state.amp_in_r = math.abs(value or 0) end)

  local function try_setup_pitch_and_conf()
    if not self.pitch_poll then
      for _, name in ipairs(PITCH_POLL_NAMES) do
        self.pitch_poll = try_poll(name, function(value) state.pitch_hz = value end)
        if self.pitch_poll then break end
      end
    end
    if not self.conf_poll then
      for _, name in ipairs(CONF_POLL_NAMES) do
        self.conf_poll = try_poll(name, function(value) state.pitch_conf = value end)
        if self.conf_poll then break end
      end
    end
  end

  try_setup_pitch_and_conf()

  if (not self.pitch_poll) or (not self.conf_poll) then
    if self.pitch_retry_metro then
      self.pitch_retry_metro:stop()
      self.pitch_retry_metro = nil
    end
    self.pitch_retry_metro = metro.init()
    if self.pitch_retry_metro then
      self.pitch_retry_metro.time = 1
      self.pitch_retry_metro.event = function()
        try_setup_pitch_and_conf()
        if self.pitch_poll and self.conf_poll and self.pitch_retry_metro then
          self.pitch_retry_metro:stop()
          self.pitch_retry_metro = nil
        end
      end
      self.pitch_retry_metro:start()
    end
  end
end

function AudioInput:ensure_healthy(opts)
  opts = opts or {}
  local state = self.state
  local now_ms = opts.now_ms or 0
  if now_ms <= 5000 then return end

  local total_amp = (state.amp_in_l or 0) + (state.amp_in_r or 0) + (state.amp_out_l or 0) + (state.amp_out_r or 0)
  local source_is_sample = opts.source_is_sample
  local audio_service = opts.audio_service
  local debug_log_fn = opts.debug_log or function() end
  local debug_should_log_fn = opts.debug_should_log or function() return false end

  if total_amp <= 0.0001 and not state.amp_poll_restart_warned then
    if debug_should_log_fn("amp_polls_dead", 10.0) then
      local audio_status = audio_service and audio_service:get_status() or {}
      debug_log_fn("H13", "audio_input:ensure_healthy", "amp_polls_dead", {
        amp_in_l = state.amp_in_l or -1,
        amp_in_r = state.amp_in_r or -1,
        amp_out_l = state.amp_out_l or -1,
        amp_out_r = state.amp_out_r or -1,
        total_amp = total_amp,
        sample_mode = source_is_sample and source_is_sample() or false,
        sample_loaded = audio_status.sample_loaded or false,
        softcut_active = audio_status.softcut_active or false,
      })
    end

    if self.amp_poll then self.amp_poll:stop() end
    if self.amp_poll_aux then self.amp_poll_aux:stop() end
    if self.amp_poll_in_l then self.amp_poll_in_l:stop() end
    if self.amp_poll_in_r then self.amp_poll_in_r:stop() end
    self.amp_poll = nil
    self.amp_poll_aux = nil
    self.amp_poll_in_l = nil
    self.amp_poll_in_r = nil

    self.amp_poll = try_poll("amp_out_l", function(value) state.amp_out_l = math.abs(value or 0) end)
    self.amp_poll_aux = try_poll("amp_out_r", function(value) state.amp_out_r = math.abs(value or 0) end)
    self.amp_poll_in_l = try_poll("amp_in_l", function(value) state.amp_in_l = math.abs(value or 0) end)
    self.amp_poll_in_r = try_poll("amp_in_r", function(value) state.amp_in_r = math.abs(value or 0) end)

    if source_is_sample and source_is_sample() and audio_service then
      audio_service:ensure_monitor_routing()
    end
    state.amp_poll_restart_warned = true
  end

  if debug_should_log_fn("system_health", 10.0) then
    local audio_status = audio_service and audio_service:get_status() or {}
    debug_log_fn("H17", "audio_input:ensure_healthy", "system_health_status", {
      total_amp = total_amp,
      sample_mode = source_is_sample and source_is_sample() or false,
      sample_loaded = audio_status.sample_loaded or false,
      amp_norm = state.amp_norm or 0,
      pitch_hz = state.pitch_hz or -1,
      pitch_conf = state.pitch_conf or 0,
      runtime_ms = now_ms,
      polls_healthy = total_amp > 0.0001,
    })
  end
end

function AudioInput:cleanup()
  if self.amp_poll then self.amp_poll:stop() end
  if self.amp_poll_aux then self.amp_poll_aux:stop() end
  if self.amp_poll_in_l then self.amp_poll_in_l:stop() end
  if self.amp_poll_in_r then self.amp_poll_in_r:stop() end
  if self.pitch_poll then self.pitch_poll:stop() end
  if self.conf_poll then self.conf_poll:stop() end
  if self.pitch_retry_metro then self.pitch_retry_metro:stop() end
  self.amp_poll = nil
  self.amp_poll_aux = nil
  self.amp_poll_in_l = nil
  self.amp_poll_in_r = nil
  self.pitch_poll = nil
  self.conf_poll = nil
  self.pitch_retry_metro = nil
end

return AudioInput
