-- nama-ReaPitchMatch: REAPER APIのモックを使った適用・ロールバックのテスト
-- 実行例: lua tests/test_reaper_logic.lua
local test_dir = debug.getinfo(1, "S").source:match("^@(.+[\\/])") or "tests/"
local root = test_dir .. "../"

local mock = {
  undo_begins = 0, undo_ends = 0, ui_refresh = 0, updates = 0,
  messages = {}, extstate = {}, modes = {}, selected_notes = {},
  midi_takes = {}, fail_key = nil, fail_take = nil, failed = false,
}
local R = {}

function R.GetMediaItemTakeInfo_Value(take, key)
  return take[key] or 0
end
function R.SetMediaItemTakeInfo_Value(take, key, value)
  if mock.fail_key == key and mock.fail_take == take and not mock.failed then
    mock.failed = true
    return false
  end
  take[key] = value
  return true
end
function R.Undo_BeginBlock2() mock.undo_begins = mock.undo_begins + 1 end
function R.Undo_EndBlock2() mock.undo_ends = mock.undo_ends + 1 end
function R.PreventUIRefresh(value) mock.ui_refresh = mock.ui_refresh + value end
function R.UpdateArrange() mock.updates = mock.updates + 1 end
function R.ShowMessageBox(text) mock.messages[#mock.messages + 1] = text; return 0 end
function R.SetExtState(section, key, value) mock.extstate[section .. ":" .. key] = value end
function R.EnumPitchShiftModes(index)
  local name = mock.modes[index + 1]
  if name then return true, name end
  return false
end
function R.GetTakeEnvelopeByName(take_object, name)
  return take_object.pitchEnvelope and {} or nil
end
function R.TakeFX_GetCount(take_object)
  return #(take_object.fx or {})
end
function R.TakeFX_GetFXName(take_object, index)
  return true, (take_object.fx or {})[index + 1] or ""
end
function R.GetMediaItemTake_Track(take_object)
  return take_object.track
end
function R.TrackFX_GetCount(track)
  return #(track.fx or {})
end
function R.TrackFX_GetFXName(track, index)
  return true, (track.fx or {})[index + 1] or ""
end

local function take(initial)
  return {
    D_PITCH = initial.pitch or 0,
    I_PITCHMODE = initial.mode or -1,
    B_PPITCH = initial.preserve or 0,
  }
end
local function entry(take_object, filename, source_note)
  return {
    take = take_object,
    filename = filename,
    source_note = source_note or 62,
    source_label = "D4",
    name_source = "ファイル名",
  }
end

_G.reaper = R
_G.NAMA_PITCHMATCH_TEST = true
dofile(root .. "nama-ReaPitchMatch.lua")
local M = assert(_G.NAMA_PITCHMATCH_TEST_API, "テスト用APIが公開されていません")

local passed = 0
local function eq(actual, expected, message)
  assert(actual == expected, string.format("%s expected %s, got %s",
    message or "", tostring(expected), tostring(actual)))
end
local function near(actual, expected, tolerance, message)
  assert(math.abs(actual - expected) <= (tolerance or 1e-8),
    string.format("%s expected %g, got %g", message or "", expected, actual))
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then error("FAIL " .. name .. "\n" .. err, 0) end
  passed = passed + 1
  print("PASS " .. name)
end
local function reset()
  mock.undo_begins, mock.undo_ends = 0, 0
  mock.ui_refresh, mock.updates = 0, 0
  mock.messages, mock.extstate = {}, {}
  mock.fail_key, mock.fail_take, mock.failed = nil, nil, false
end

local soloist = { index = 2, name = "Soloist v2.10", version = { 2, 10 } }
local project = {}

test("read/write settings", function()
  local object = take({ pitch = 1.5, mode = 131079, preserve = 1 })
  local settings = M.read_settings(object)
  near(settings.pitch, 1.5)
  eq(settings.mode, 131079)
  eq(settings.preserve, 1)
  M.write_settings(object, { pitch = -2, mode = 65536, preserve = 0 })
  near(object.D_PITCH, -2)
  eq(object.I_PITCHMODE, 65536)
  eq(object.B_PPITCH, 0)
end)

test("pitch_warnings: existing pitch, playrate, envelope, takeFX, trackFX", function()
  local object = take({ pitch = 1.5, preserve = 0 })
  object.D_PLAYRATE = 0.5
  object.pitchEnvelope = true
  object.fx = { "ReaPitch" }
  object.track = { fx = { "ReaPitch" } }
  local item = entry(object, "a_D4.wav", 62)
  item.old = M.read_settings(object)
  local warnings = M.pitch_warnings(item)
  local text = table.concat(warnings, "\n")
  assert(text:find("既存ピッチ", 1, true))
  assert(text:find("再生レート", 1, true))
  assert(text:find("Pitch Envelope", 1, true))
  assert(text:find("テイクFX", 1, true))
  assert(text:find("トラックFX", 1, true))
end)

test("apply_entries: basic pitch change and undo block", function()
  reset()
  local object = take({})
  M.apply_entries(project, { entry(object, "a_D4.wav", 62) }, {}, soloist, 64, "E4", false)
  near(object.D_PITCH, 2)
  eq(object.I_PITCHMODE, soloist.index * 65536)
  eq(object.B_PPITCH, 1)
  eq(mock.undo_begins, 1)
  eq(mock.undo_ends, 1)
  assert(mock.messages[#mock.messages]:find("1 件を変更しました", 1, true))
end)

test("apply_entries: preserves Soloist submode", function()
  reset()
  local object = take({ mode = soloist.index * 65536 + 7 })
  M.apply_entries(project, { entry(object, "a_D4.wav", 62) }, {}, soloist, 64, "E4", false)
  eq(object.I_PITCHMODE, soloist.index * 65536 + 7)
  near(object.D_PITCH, 2)
end)

test("apply_entries: already correct does not create undo", function()
  reset()
  local object = take({ pitch = 2, mode = soloist.index * 65536, preserve = 1 })
  M.apply_entries(project, { entry(object, "a_D4.wav", 62) }, {}, soloist, 64, "E4", false)
  eq(mock.undo_begins, 0)
  assert(mock.messages[#mock.messages]:find("すでに指定の設定", 1, true))
end)

test("apply_entries: rollback on write failure", function()
  reset()
  local first = take({})
  local second = take({})
  mock.fail_key, mock.fail_take = "D_PITCH", second
  M.apply_entries(project, {
    entry(first, "a_D4.wav", 62),
    entry(second, "b_D4.wav", 62),
  }, {}, soloist, 64, "E4", false)
  near(first.D_PITCH, 0)
  eq(first.I_PITCHMODE, -1)
  eq(first.B_PPITCH, 0)
  near(second.D_PITCH, 0)
  eq(second.I_PITCHMODE, -1)
  eq(second.B_PPITCH, 0)
  assert(mock.messages[#mock.messages]:find("処理に失敗しました", 1, true))
  assert(mock.messages[#mock.messages]:find("元に戻しました", 1, true))
end)

test("apply_entries: analysis failure is reported but pitch still applies", function()
  reset()
  local object = take({})
  local item = entry(object, "a_D4.wav", 62)
  item.correction = 0
  item.analysis_failed = true
  item.analysis_status = "安定した有声音を検出できないため補正なし"
  M.apply_entries(project, { item }, {}, soloist, 64, "E4", true)
  near(object.D_PITCH, 2)
  assert(mock.messages[#mock.messages]:find("セント補正：0 件成功／1 件は補正なし", 1, true))
end)

test("find_soloist: newest version wins", function()
  reset()
  mock.modes = { "Project default", "Soloist v2.9", "Soloist v2.10", "Other" }
  local best = M.find_soloist()
  eq(best.index, 2)
  eq(best.name, "Soloist v2.10")
  eq(#M.pitch_mode_names(), 4)
end)

test("find_soloist: missing", function()
  reset()
  mock.modes = { "Project default", "Other" }
  eq(M.find_soloist(), nil)
end)

local function make_midi_mock()
  local midi_take = {}
  mock.midi_take = midi_take
  mock.midi_takes = { midi_take }
  mock.midi_editor = {}
  mock.active_take = midi_take
  R.MIDIEditor_GetActive = function() return mock.midi_editor end
  R.MIDIEditor_GetTake = function() return mock.active_take end
  R.ValidatePtr2 = function(_, pointer, kind)
    return kind == "MediaItem_Take*" and pointer == midi_take
  end
  R.TakeIsMIDI = function(value) return value == midi_take end
  R.MIDIEditor_EnumTakes = function(_, index) return mock.midi_takes[index + 1] end
  R.MIDI_EnumSelNotes = function(_, previous)
    if previous + 1 < #mock.selected_notes then return previous + 1 end
    return -1
  end
  R.MIDI_GetNote = function(_, index)
    return true, true, false, 0, 0, 1, mock.selected_notes[index + 1], 100
  end
end

test("selected_midi_target: single note", function()
  reset()
  make_midi_mock()
  mock.selected_notes = { 64 }
  local target, status, clear = M.selected_midi_target(project)
  eq(target, 64)
  eq(status, "MIDIから自動入力")
  eq(clear, false)
end)

test("selected_midi_target: same pitch twice", function()
  reset()
  make_midi_mock()
  mock.selected_notes = { 64, 64 }
  eq(M.selected_midi_target(project), 64)
end)

test("selected_midi_target: different pitches", function()
  reset()
  make_midi_mock()
  mock.selected_notes = { 64, 67 }
  local target, status, clear = M.selected_midi_target(project)
  eq(target, nil)
  eq(status, "MIDI：複数音程／手入力")
  eq(clear, true)
end)

test("selected_midi_target: no selection", function()
  reset()
  make_midi_mock()
  mock.selected_notes = {}
  local target, status, clear = M.selected_midi_target(project)
  eq(target, nil)
  eq(status, "MIDI：未選択／手入力")
  eq(clear, false)
end)

test("source_filename: follows parent source", function()
  reset()
  local source, parent = {}, {}
  R.GetMediaItemTake_Source = function() return source end
  R.GetMediaSourceParent = function(value)
    if value == source then return parent end
    return nil
  end
  R.GetMediaSourceFileName = function(value)
    if value == parent then return "C:\\audio\\foo_D4.wav" end
    return ""
  end
  eq(M.source_filename({}), "C:\\audio\\foo_D4.wav")
end)

test("source_filename: cycle is rejected", function()
  reset()
  local source, parent = {}, {}
  R.GetMediaItemTake_Source = function() return source end
  R.GetMediaSourceParent = function(value)
    if value == source then return parent end
    return source
  end
  R.GetMediaSourceFileName = function() return "unused" end
  eq(M.source_filename({}), "")
end)

print(string.format("OK: %d tests passed", passed))
