-- Audio output: DAC/cut levels and engine/cut mix. No engine commands (those live in synth_service).

local AudioOutput = {}
AudioOutput.__index = AudioOutput

function AudioOutput.new(_opts)
  return setmetatable({}, AudioOutput)
end

function AudioOutput:setup()
  pcall(function() audio.level_dac(1.0) end)
  pcall(function() audio.level_cut(1.0) end)
  pcall(function() audio.level_eng(1.0) end)
  pcall(function() audio.level_monitor(0) end)
end

function AudioOutput:set_engine_cut_level(level)
  local L = level and level > 0 and level or 0
  pcall(function() audio.level_eng_cut(L) end)
  if L > 0 then
    pcall(function() audio.level_eng(1.0) end)
    pcall(function() audio.level_cut(1.0) end)
  end
end

function AudioOutput:cleanup()
  pcall(function() audio.level_eng_cut(0) end)
end

return AudioOutput
