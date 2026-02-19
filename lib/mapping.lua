local Mapping = {}

local SCALE_DEGREES = {
  chromatic = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11},
  major = {0, 2, 4, 5, 7, 9, 11},
  minor = {0, 2, 3, 5, 7, 8, 10},
  dorian = {0, 2, 3, 5, 7, 9, 10},
  mixolydian = {0, 2, 4, 5, 7, 9, 10},
  pentatonic = {0, 2, 4, 7, 9},
}

local function round(value)
  if value >= 0 then
    return math.floor(value + 0.5)
  end
  return math.ceil(value - 0.5)
end

local function clamp(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

function Mapping.hz_to_midi(hz)
  if hz == nil or hz <= 0 then
    return nil
  end
  return 69 + 12 * (math.log(hz / 440) / math.log(2))
end

function Mapping.clamp_midi(midi_note, midi_min, midi_max)
  if midi_note == nil then
    return nil
  end
  return clamp(round(midi_note), midi_min, midi_max)
end

function Mapping.get_scale_names()
  return {"chromatic", "major", "minor", "dorian", "mixolydian", "pentatonic"}
end

function Mapping.quantize_midi(midi_note, scale_name, root)
  if midi_note == nil then
    return nil
  end

  local degrees = SCALE_DEGREES[scale_name] or SCALE_DEGREES.chromatic
  if degrees == SCALE_DEGREES.chromatic then
    return round(midi_note)
  end

  local reference_root = root or 0
  local nearest = nil
  local nearest_distance = math.huge
  local center = round(midi_note)
  local octave = math.floor((center - reference_root) / 12)

  for octave_offset = -2, 2 do
    local base = (octave + octave_offset) * 12 + reference_root
    for _, degree in ipairs(degrees) do
      local candidate = base + degree
      local distance = math.abs(candidate - midi_note)
      if distance < nearest_distance then
        nearest = candidate
        nearest_distance = distance
      end
    end
  end

  return nearest or round(midi_note)
end

return Mapping
