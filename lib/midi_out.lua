local MidiOut = {}
MidiOut.__index = MidiOut

local function clamp(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

local function round(value)
  if value >= 0 then
    return math.floor(value + 0.5)
  end
  return math.ceil(value - 0.5)
end

function MidiOut.new()
  local self = setmetatable({}, MidiOut)
  self.device_id = 1
  self.channel = 1
  self.note_length_ms = 150
  self.velocity_mode = "amp"
  self.fixed_velocity = 100
  self.send_enabled = true
  self.conn = midi.connect(self.device_id)
  return self
end

function MidiOut.list_devices()
  local options = {}
  for index, port in ipairs(midi.vports) do
    options[index] = port.name ~= "" and port.name or ("midi " .. index)
  end

  if #options == 0 then
    options = {"none"}
  end

  return options
end

function MidiOut:set_device(device_id)
  self.device_id = clamp(device_id, 1, math.max(1, #midi.vports))
  self.conn = midi.connect(self.device_id)
end

function MidiOut:set_channel(channel)
  self.channel = clamp(channel, 1, 16)
end

function MidiOut:set_note_length_ms(note_length_ms)
  self.note_length_ms = clamp(note_length_ms, 10, 4000)
end

function MidiOut:set_velocity_mode(mode)
  self.velocity_mode = mode == "fixed" and "fixed" or "amp"
end

function MidiOut:set_fixed_velocity(value)
  self.fixed_velocity = clamp(round(value), 1, 127)
end

function MidiOut:set_send_enabled(enabled)
  self.send_enabled = enabled and true or false
end

function MidiOut:velocity_from_amp(amp)
  local clipped = clamp(amp or 0, 0, 1)
  local curved = math.sqrt(clipped)
  return clamp(round(1 + curved * 126), 1, 127)
end

function MidiOut:trigger_note(note, amp)
  if not self.send_enabled or self.conn == nil or note == nil then
    return
  end

  local send_fn = self.conn.send
  if type(send_fn) ~= "function" then
    return
  end

  local midi_note = clamp(round(note), 0, 127)
  local channel = clamp(round(tonumber(self.channel) or 1), 1, 16)
  local velocity = self.fixed_velocity
  if self.velocity_mode == "amp" then
    velocity = self:velocity_from_amp(amp)
  end

  local message_on = midi.to_msg({type = "note_on", ch = channel, note = midi_note, vel = velocity})
  local message_off = midi.to_msg({type = "note_off", ch = channel, note = midi_note, vel = 0})
  if message_on == nil or message_off == nil then
    return
  end

  local ok_on = pcall(function()
    self.conn:send(message_on)
  end)
  if not ok_on then
    return
  end
  clock.run(function()
    clock.sleep(self.note_length_ms / 1000)
    if self.conn then
      pcall(function()
        self.conn:send(message_off)
      end)
    end
  end)
end

return MidiOut
