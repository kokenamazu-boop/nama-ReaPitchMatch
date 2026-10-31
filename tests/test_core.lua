-- nama-ReaPitchMatch: REAPERに依存しない関数のテスト
-- 実行例: lua tests/test_core.lua
local test_dir = debug.getinfo(1, "S").source:match("^@(.+[\\/])") or "tests/"
local root = test_dir .. "../"

_G.NAMA_PITCHMATCH_TEST = true
dofile(root .. "Jinriki_FilenamePitch_to_Target_Soloist.lua")
local M = assert(_G.NAMA_PITCHMATCH_TEST_API, "テスト用APIが公開されていません")

local passed = 0
local function eq(actual, expected, message)
  assert(actual == expected, string.format("%s expected %s, got %s",
    message or "", tostring(expected), tostring(actual)))
end
local function near(actual, expected, tolerance, message)
  assert(type(actual) == "number", (message or "") .. " not a number: " .. tostring(actual))
  assert(math.abs(actual - expected) <= (tolerance or 1e-8),
    string.format("%s expected %g +/- %g, got %g", message or "", expected, tolerance or 1e-8, actual))
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then error("FAIL " .. name .. "\n" .. err, 0) end
  passed = passed + 1
  print("PASS " .. name)
end
local function sine(frequency, rate, count, amplitude)
  local samples = {}
  for index = 1, count do
    samples[index] = (amplitude or 0.5) * math.sin(2 * math.pi * frequency * (index - 1) / rate)
  end
  return samples
end
local function cents(frequency, expected)
  return 1200 * math.log(frequency / expected) / math.log(2)
end

test("trim", function()
  eq(M.trim("  C4\t"), "C4")
  eq(M.trim(""), "")
end)

test("normalize_symbols", function()
  eq(M.normalize_symbols("Ｆ＃４"), "F#4")
  eq(M.normalize_symbols("A♯3"), "A#3")
  eq(M.normalize_symbols("B♭2"), "Bb2")
  eq(M.normalize_symbols("Ｄ４"), "D4")
  eq(M.normalize_symbols("（Ｃ４）"), "(C4)")
  eq(M.normalize_symbols("％"), "%")
end)

test("parse_note", function()
  local note, label = M.parse_note("E4")
  eq(note, 64); eq(label, "E4")
  note, label = M.parse_note("F#3")
  eq(note, 54); eq(label, "F#3")
  note, label = M.parse_note("Bb2")
  eq(note, 46); eq(label, "Bb2")
  note, label = M.parse_note("C-1")
  eq(note, 0); eq(label, "C-1")
  note, label = M.parse_note("C4#")
  eq(note, 61); eq(label, "C#4")
  note, label = M.parse_note("Ｆ＃４")
  eq(note, 66); eq(label, "F#4")
  note, label = M.parse_note("ｃ４")
  eq(note, 60); eq(label, "C4")
  note, label = M.parse_note(" C 4 ")
  eq(note, 60); eq(label, "C4")
  eq(M.parse_note("H4"), nil)
  eq(M.parse_note("C10"), nil)
  eq(M.parse_note("C#4b"), nil)
  eq(M.parse_note(""), nil)
end)

test("midi_note_name", function()
  eq(M.midi_note_name(60), "C4")
  eq(M.midi_note_name(61), "C#4")
  eq(M.midi_note_name(0), "C-1")
  eq(M.midi_note_name(127), "G9")
end)

test("strip_audio_extension", function()
  eq(M.strip_audio_extension("foo.wav"), "foo")
  eq(M.strip_audio_extension("foo.WAV"), "foo")
  eq(M.strip_audio_extension("foo.mp3"), "foo")
  eq(M.strip_audio_extension("foo.C4"), "foo.C4")
  eq(M.strip_audio_extension("foo.C4.wav"), "foo.C4")
  eq(M.strip_audio_extension("foo.tar.gz"), "foo.tar.gz")
  eq(M.strip_audio_extension("foo"), "foo")
end)

test("note_from_filename: basic names", function()
  local note, label, reason, code = M.note_from_filename("り_D4_30.wav")
  eq(note, 62); eq(label, "D4"); eq(reason, nil); eq(code, "ok")
  note, label = M.note_from_filename("E3_あ.wav")
  eq(note, 52); eq(label, "E3")
  note, label = M.note_from_filename("あ_F#3.wav")
  eq(note, 54); eq(label, "F#3")
  note, label = M.note_from_filename("BGM_01_A4.wav")
  eq(note, 69); eq(label, "A4")
  note, label = M.note_from_filename("foo.A4.wav")
  eq(note, 69); eq(label, "A4")
  note, label = M.note_from_filename("vocal_A4_take2.wav")
  eq(note, 69); eq(label, "A4")
  note, label = M.note_from_filename("りD4.wav")
  eq(note, 62); eq(label, "D4")
end)

test("note_from_filename: full-width and accidental after octave", function()
  local note, label = M.note_from_filename("Ｄ４.wav")
  eq(note, 62); eq(label, "D4")
  note, label = M.note_from_filename("A4#.wav")
  eq(note, 70); eq(label, "A#4")
  note, label = M.note_from_filename("D4b.wav")
  eq(note, 61); eq(label, "Db4")
  note, label = M.note_from_filename("C#4.wav")
  eq(note, 61); eq(label, "C#4")
end)

test("note_from_filename: rejects words and duplicates", function()
  local note, label, reason, code = M.note_from_filename("take2.wav")
  eq(note, nil); eq(label, nil); eq(code, "none")
  assert(reason:find("ファイル名から音名を読めません", 1, true))
  note, label, reason, code = M.note_from_filename("C4bar.wav")
  eq(note, nil); eq(code, "none")
  note, label, reason, code = M.note_from_filename("foo_barD4.wav")
  eq(note, nil); eq(code, "none")
  note, label, reason, code = M.note_from_filename("foo_C4_C4.wav")
  eq(note, 60); eq(label, "C4"); eq(code, "ok")
  note, label, reason, code = M.note_from_filename("foo_C4_G4.wav")
  eq(note, nil); eq(code, "multiple")
  assert(reason:find("C4", 1, true))
  assert(reason:find("G4", 1, true))
end)

test("note_from_take_name", function()
  local note, label = M.note_from_take_name("vocal take_D4")
  eq(note, 62); eq(label, "D4")
  local _, _, reason, code = M.note_from_take_name("take 4")
  eq(code, "none")
  assert(reason:find("テイク名", 1, true))
end)

test("median", function()
  near(M.median({ 3, 1, 2 }), 2)
  near(M.median({ 4, 1, 3, 2 }), 2.5)
  near(M.median({ 5 }), 5)
end)

test("frame_pitch: sine at expected pitch", function()
  local frequency, rms, confidence = M.frame_pitch(sine(440, 12000, 512), 12000, 440, false)
  near(frequency, 440, 2)
  assert(rms > 0.1)
  assert(confidence > 0.8 and confidence <= 1.0001)
end)

test("frame_pitch: +100 cents", function()
  local frequency = M.frame_pitch(sine(466.1637615, 12000, 512), 12000, 440, false)
  near(cents(frequency, 440), 100, 2)
end)

test("frame_pitch: octave-up sine stays up", function()
  local frequency = M.frame_pitch(sine(880, 12000, 512), 12000, 440, false)
  near(frequency, 880, 4)
end)

test("frame_pitch: silence and very quiet input", function()
  local silence = {}
  for index = 1, 512 do silence[index] = 0 end
  eq(M.frame_pitch(silence, 12000, 440, false), nil)
  eq(M.frame_pitch(sine(440, 12000, 512, 0.0001), 12000, 440, false), nil)
end)

local function observation(time, value, rms, confidence)
  return { time = time, cents = value, rms = rms or 0.5, confidence = confidence or 0.99 }
end

test("choose_estimate: stable plateau", function()
  local observations = {}
  for index = 1, 10 do observations[index] = observation(index * 0.01, 10, 0.5) end
  local value, description, _, _, quality = M.choose_estimate(observations, 0.1, 440, 0.01)
  near(value, 10, 1)
  eq(type(description), "string")
  eq(quality.frames, 10)
  eq(quality.voiced, 10)
  near(quality.voiced_ratio, 1.0)
  assert(quality.confidence > 0.9)
end)

test("source_range: non-loop", function()
  local start, span = M.source_range(2.0, 0.0, 1.0, false)
  near(start, 0.0); near(span, 1.0)
  start, span = M.source_range(2.0, 1.5, 1.0, false)
  near(start, 1.5); near(span, 0.5)
  start, span = M.source_range(2.0, -0.5, 1.0, false)
  near(start, 0.0); near(span, 0.5)
end)

test("source_range: loop", function()
  local start, span = M.source_range(1.0, 0.5, 2.0, true)
  near(start, 0.0); near(span, 1.0)
  start, span = M.source_range(2.0, 1.5, 1.0, true)
  near(start, 1.5); near(span, 0.5)
  eq(M.source_range(0.0, 0.0, 1.0, false), nil)
end)

test("intersect_time_selection", function()
  local start, finish, limited = M.intersect_time_selection(10, 2, 0, 0)
  near(start, 10); near(finish, 12); eq(limited, false)
  start, finish, limited = M.intersect_time_selection(10, 2, 10.5, 11.5)
  near(start, 10.5); near(finish, 11.5); eq(limited, true)
  start, finish, limited = M.intersect_time_selection(10, 2, 8, 13)
  near(start, 10); near(finish, 12); eq(limited, true)
  eq(M.intersect_time_selection(10, 2, 12, 13), nil)
end)

test("choose_estimate: competing plateau is rejected", function()
  local observations = {}
  for index = 1, 10 do observations[index] = observation(index * 0.01, 10, 0.5) end
  for index = 11, 20 do observations[index] = observation(index * 0.01, 60, 0.5) end
  local value, _, reason, conflict = M.choose_estimate(observations, 0.2, 440, 0.01)
  eq(value, nil)
  eq(conflict, true)
  assert(reason:find("別の音程", 1, true))
end)

test("choose_estimate: short voiced tail", function()
  local observations = {
    observation(0.010, 10, 0.5, 0.98),
    observation(0.020, 12, 0.5, 0.98),
  }
  local value, description = M.choose_estimate(observations, 0.05, 440, 0.01)
  near(value, 11, 0.5)
  assert(description:find("短い有声区間", 1, true))
end)

test("choose_estimate: unstable pitch is rejected", function()
  local observations = {}
  for index = 1, 20 do
    observations[index] = observation(index * 0.01, index % 2 == 0 and 40 or -40, 0.5)
  end
  local value, _, reason = M.choose_estimate(observations, 0.2, 440, 0.01)
  eq(value, nil)
  assert(type(reason) == "string" and #reason > 0)
end)

test("version comparison", function()
  local left = M.version_parts("Soloist v2.10")
  local right = M.version_parts("Soloist v2.9")
  eq(table.concat(left, "."), "2.10")
  eq(table.concat(right, "."), "2.9")
  eq(M.newer_version(left, right), true)
  eq(M.newer_version(right, left), false)
  eq(M.newer_version(M.version_parts("2.9.1"), M.version_parts("2.9")), true)
  eq(M.newer_version(M.version_parts("2.9"), M.version_parts("2.9.1")), false)
end)

test("report_rows truncation", function()
  local rows = {}
  for index = 1, 20 do rows[index] = "row " .. index end
  local text = M.report_rows(rows)
  assert(text:find("row 16", 1, true))
  assert(not text:find("row 17", 1, true))
  assert(text:find("…ほか 4 件", 1, true))
end)

print(string.format("OK: %d tests passed", passed))
