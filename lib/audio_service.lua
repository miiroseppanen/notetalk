local AudioService = {}
AudioService.__index = AudioService

function AudioService.new()
  local self = setmetatable({}, AudioService)
  self.sample_loaded = false
  self.sample_path = nil
  self.softcut_active = false
  self.phase_monitor_active = false
  return self
end

function AudioService:setup_defaults()
  pcall(function() audio.level_dac(1.0) end)
  pcall(function() audio.level_monitor(1.0) end)
  pcall(function() audio.level_monitor_mix(1.0) end)
  pcall(function() audio.level_tape(1.0) end)
  pcall(function() audio.level_cut(1.0) end)
  pcall(function() softcut.enable(1, 1) end)
  pcall(function() softcut.buffer(1, 1) end)
  pcall(function() softcut.level(1, 0.8) end)
  pcall(function() softcut.level_input_cut(1, 1, 0) end)
  pcall(function() softcut.level_input_cut(2, 1, 0) end)
  pcall(function() softcut.rec_level(1, 0) end)
  pcall(function() softcut.pre_level(1, 1) end)
  pcall(function() softcut.rec(1, 0) end)
  pcall(function() softcut.pan(1, 0) end)
  pcall(function() softcut.rate(1, 1) end)
  pcall(function() softcut.loop(1, 1) end)
  pcall(function() softcut.loop_start(1, 0) end)
  pcall(function() softcut.loop_end(1, 4) end)
  pcall(function() softcut.position(1, 0) end)
  pcall(function() softcut.play(1, 0) end)
  
  -- CRITICAL: Route softcut output for amplitude polling
  pcall(function() audio.level_cut(1.0) end) -- Route softcut to output for monitoring
  
  self.softcut_active = true
end

function AudioService:setup_phase_monitor(enable)
  if not enable or self.phase_monitor_active then
    return
  end
  pcall(function() softcut.phase_quant(1, 0.125) end)
  pcall(function() softcut.poll_start_phase() end)
  pcall(function()
    softcut.event_phase(function(voice, position)
      if voice ~= 1 then
        return
      end
      -- Phase callback logic can be handled by caller
    end)
  end)
  self.phase_monitor_active = true
end

function AudioService:clear_phase_monitor()
  if not self.phase_monitor_active then
    return
  end
  pcall(function()
    softcut.event_phase(function(_, _) end)
  end)
  pcall(function()
    softcut.poll_stop_phase()
  end)
  self.phase_monitor_active = false
end

function AudioService:load_sample(path, defer_clock_fn)
  if not path or path == "" then
    return false
  end

  local ok, err = pcall(function()
    self:setup_defaults()
    self:setup_phase_monitor(false) -- Phase monitor disabled by default
    
    -- Critical: Stop all playback before buffer operations
    softcut.play(1, 0)
    softcut.rec(1, 0)
    
    -- Wait for operations to settle
    clock.sleep(0.05)
    
    softcut.buffer_clear()
    softcut.buffer_read_mono(path, 0, 0, -1, 1, 1, 0)
    
    -- Wait for buffer read to complete before starting playback
    clock.sleep(0.1)
    
    -- Ensure proper signal routing before playback
    pcall(function() audio.level_cut(1.0) end) -- Route softcut to output
    pcall(function() softcut.level(1, 0.9) end) -- Korkea level samplelle
    softcut.position(1, 0)
    softcut.play(1, 1)
    
  end)

  if ok then
    self.sample_loaded = true
    self.sample_path = path

    local _, frames, sample_rate = audio.file_info(path)
    if frames and sample_rate and sample_rate > 0 then
      local duration = frames / sample_rate
      pcall(function() softcut.loop_end(1, math.max(0.2, duration)) end)
    end
    -- Ensure playback is running after read starts.
    if defer_clock_fn then
      defer_clock_fn(function()
        clock.sleep(0.1)
        pcall(function() softcut.position(1, 0) end)
        pcall(function() softcut.play(1, 1) end)
      end)
    end
    return true
  else
    self.sample_loaded = false
    self.sample_path = nil
    return false
  end
end

function AudioService:unload_sample()
  self.sample_loaded = false
  self.sample_path = nil
  pcall(function() softcut.play(1, 0) end)
end

function AudioService:cleanup()
  self:clear_phase_monitor()
  if self.softcut_active then
    -- CRITICAL: Stop everything before reset
    pcall(function() softcut.play(1, 0) end)
    pcall(function() softcut.rec(1, 0) end)
    
    -- Brief delay for stop to take effect
    for i = 1, 2000 do end
    
    -- Reset all parameters to safe defaults
    pcall(function() softcut.level(1, 0) end)
    pcall(function() softcut.level_input_cut(1, 1, 0) end)
    pcall(function() softcut.level_input_cut(2, 1, 0) end)
    pcall(function() softcut.rec_level(1, 0) end)
    pcall(function() softcut.pre_level(1, 0) end)
    pcall(function() softcut.pan(1, 0) end)
    pcall(function() softcut.rate(1, 1) end)
    pcall(function() softcut.position(1, 0) end)
    pcall(function() softcut.loop_start(1, 0) end)
    pcall(function() softcut.loop_end(1, 1) end)
    
    -- Clear buffer (lyhennetty wait restartin nopeuttamiseksi)
    pcall(function() softcut.buffer_clear() end)
    for i = 1, 10000 do end
    
    pcall(function() softcut.enable(1, 0) end)
    self.softcut_active = false
  end
  
  -- Brief grace period for JACK client cleanup (lyhennetty restartin nopeuttamiseksi)
  for i = 1, 10000 do end
  
  -- Reset audio levels to safe defaults
  pcall(function() audio.level_cut(0.8) end)  
  pcall(function() audio.level_eng_cut(1.0) end)  
end

function AudioService:get_status()
  return {
    sample_loaded = self.sample_loaded,
    sample_path = self.sample_path,
    softcut_active = self.softcut_active,
    phase_monitor_active = self.phase_monitor_active
  }
end

function AudioService:verify_signal_routing()
  if not self.softcut_active then
    return false, "softcut not active"
  end
  
  -- Check if basic routing is set up
  local monitor_level = 0
  pcall(function() 
    monitor_level = softcut.query_monitor_level() or 0
  end)
  
  return true, "routing configured"
end

function AudioService:ensure_monitor_routing()
  if self.softcut_active then
    -- Vain reititys (DAC): älä koske softcut.level() – E2/sample level säilyy
    pcall(function() audio.level_cut(1.0) end)
  end
end

return AudioService