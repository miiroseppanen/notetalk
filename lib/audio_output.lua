-- Audio output: DAC/cut levels and engine/cut mix. No engine commands (those live in synth_service).

local AudioOutput = {}
AudioOutput.__index = AudioOutput

function AudioOutput.new(_opts)
  return setmetatable({}, AudioOutput)
end

function AudioOutput:setup()
  pcall(function() audio.level_dac(1.0) end)
  pcall(function() audio.level_cut(1.0) end)
end

function AudioOutput:set_engine_cut_level(level)
  pcall(function() audio.level_eng_cut(level or 0) end)
end

function AudioOutput:cleanup()
  pcall(function() audio.level_eng_cut(0) end)
end

return AudioOutput
