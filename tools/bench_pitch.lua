-- Pitch benchmark harness for nama-ReaPitchMatch.
-- Reads a TSV manifest of raw mono float32 segments, runs the same
-- frame_pitch/choose_estimate pipeline as the script, and writes TSV results.
--
-- Usage: lua tools/bench_pitch.lua manifest.tsv results.tsv
--
-- Manifest columns:
--   id  raw_path  sample_rate  expected_hz  span_seconds  short(0/1)
--
-- This harness is intentionally outside the production script. It uses the
-- public test hook in Jinriki_FilenamePitch_to_Target_Soloist.lua so the
-- detector itself is not duplicated.
local tool_dir = debug.getinfo(1, "S").source:match("^@(.+[\\/])") or "tools/"
local root = tool_dir .. "../"

_G.NAMA_PITCHMATCH_TEST = true
dofile(root .. "Jinriki_FilenamePitch_to_Target_Soloist.lua")
local M = assert(_G.NAMA_PITCHMATCH_TEST_API, "test API is not available")

local manifest_path, output_path = arg[1], arg[2]
if not manifest_path or not output_path then
  io.stderr:write("usage: lua tools/bench_pitch.lua manifest.tsv results.tsv\n")
  os.exit(2)
end

local function split_tsv(line)
  local fields = {}
  for field in (line .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = field end
  return fields
end

local function read_float32(path)
  local file = assert(io.open(path, "rb"))
  local data = file:read("*a")
  file:close()
  local count = math.floor(#data / 4)
  local samples = {}
  local position = 1
  for index = 1, count do
    local value
    value, position = string.unpack("<f", data, position)
    samples[index] = value
  end
  return samples
end

local function analyze(samples, sample_rate, expected, span, short)
  if #samples < 32 then return nil, "サンプル不足" end
  local failure
  for pass, periods in ipairs({ 6, 4 }) do
    local frame_span = math.max(pass == 1 and 0.018 or 0.010, periods / expected)
    frame_span = math.min(frame_span, span * 0.85)
    local count = math.floor(sample_rate * frame_span)
    if count >= 16 and count <= #samples then
      local cap = pass == 1 and 96 or 128
      local frame_duration = count / sample_rate
      local frames = math.min(cap, math.max(3,
        math.floor((span - frame_duration) / math.max(0.002, frame_duration * 0.2)) + 1))
      local observations, window = {}, {}
      for frame = 1, frames do
        local start = math.floor((#samples - count) * (frame - 1) / math.max(1, frames - 1)) + 1
        for index = 1, count do window[index] = samples[start + index - 1] end
        local frequency, rms, confidence = M.frame_pitch(window, sample_rate, expected, short)
        if frequency then
          local cents = 1200 * math.log(frequency / expected) / math.log(2)
          observations[#observations + 1] = {
            cents = cents, rms = rms, confidence = confidence,
            time = (start + count / 2) / sample_rate,
          }
        end
      end
      if #observations > 0 then
        local hop = frames > 1
          and ((#samples - count) / (frames - 1) / sample_rate)
          or math.max(0.002, frame_duration)
        local cents, description, reason, conflict =
          M.choose_estimate(observations, span, expected, hop)
        if cents then
          return cents, description, #observations, "ok"
        end
        if conflict then
          return nil, reason, #observations, "conflict"
        end
        failure = reason
      end
    end
  end
  return nil, failure or "解析できるフレームがない", 0, "none"
end

local manifest = assert(io.open(manifest_path, "r"))
local output = assert(io.open(output_path, "wb"))
output:write("id\tstatus\tcents\testimated_hz\tobservations\tdescription\n")

for line in manifest:lines() do
  if line ~= "" then
    local fields = split_tsv(line)
    local id, path = fields[1], fields[2]
    local sample_rate = tonumber(fields[3])
    local expected = tonumber(fields[4])
    local span = tonumber(fields[5])
    local short = fields[6] == "1"
    if not id or not path or not sample_rate or not expected or not span then
      output:write(string.format("%s\terror\t\t\t\tbad manifest row\n", id or "?"))
    else
      local ok, samples = pcall(read_float32, path)
      if not ok then
        output:write(string.format("%s\terror\t\t\t\tread failed\n", id))
      else
        local cents, description, observations, status =
          analyze(samples, sample_rate, expected, span, short)
        if cents then
          local estimated = expected * 2 ^ (cents / 1200)
          output:write(string.format("%s\t%s\t%.6f\t%.6f\t%d\t%s\n",
            id, status, cents, estimated, observations, description or ""))
        else
          output:write(string.format("%s\t%s\t\t\t%d\t%s\n",
            id, status, observations or 0, description or ""))
        end
      end
    end
  end
end

manifest:close()
output:close()
