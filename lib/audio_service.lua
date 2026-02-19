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
  pcall(function() softcut.level(1, 1) end)
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
  self.softcut_active = true
  print("audio_service: defaults setup, softcut_active=true")
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
  print("audio_service: phase monitor started")
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
  print("audio_service: phase monitor cleared")
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
    
    softcut.position(1, 0)
    softcut.play(1, 1)
  end)

  if ok then
    self.sample_loaded = true
    self.sample_path = path
    print("audio_service: sample loaded: " .. path)

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
    print("audio_service: sample load failed: " .. tostring(err))
    return false
  end
end

function AudioService:unload_sample()
  self.sample_loaded = false
  self.sample_path = nil
  pcall(function() softcut.play(1, 0) end)
  print("audio_service: sample unloaded")
end

function AudioService:cleanup()
  print("audio_service cleanup start")
  self:clear_phase_monitor()
  if self.softcut_active then
    -- CRITICAL: Stop everything before reset
    print("audio_service: stopping all softcut operations")
    pcall(function() softcut.play(1, 0) end)
    pcall(function() softcut.rec(1, 0) end)
    
    -- Wait for stop to take effect
    clock.sleep(0.05)
    
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
    
    -- CRITICAL: Clear buffer last and wait
    print("audio_service: clearing buffer")
    pcall(function() softcut.buffer_clear() end)
    clock.sleep(0.1)  -- Critical wait for buffer operations
    
    -- Critical: wait for buffer operations to complete
    print("audio_service: waiting for buffer operations to settle...")
    for i = 1, 10 do
      if _norns and _norns.crow then  -- Only if available
        _norns.crow.sleep(0.01)
      else
        -- Fallback busy wait
        local start = util.time()
        while (util.time() - start) < 0.01 do end
      end
    end
    
    pcall(function() softcut.enable(1, 0) end)
    self.softcut_active = false
    print("audio_service: full softcut reset completed")
  end
  
  -- Extended grace period for JACK client cleanup
  print("audio_service: grace period for JACK state cleanup...")
  for i = 1, 20 do
    if _norns and _norns.crow then 
      _norns.crow.sleep(0.005)
    else
      local start = util.time()
      while (util.time() - start) < 0.005 do end
    end
  end
  
  -- Reset audio levels to safe defaults
  pcall(function() audio.level_cut(0.8) end)  
  pcall(function() audio.level_eng_cut(1.0) end)  
  print("audio_service cleanup end")
end

function AudioService:get_status()
  return {
    sample_loaded = self.sample_loaded,
    sample_path = self.sample_path,
    softcut_active = self.softcut_active,
    phase_monitor_active = self.phase_monitor_active
  }
end

return AudioService