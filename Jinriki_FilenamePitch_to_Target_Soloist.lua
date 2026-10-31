-- @description 人力：ファイル名から目標音へ移調（Soloist）
-- @version 1.8.0
-- @author Koke
-- @link https://github.com/kokenamazu-boop/nama-ReaPitchMatch
-- @changelog
--   1.8.0 時間選択がある場合は、その範囲だけを解析。解析結果に検出フレーム数と確信度を表示。
--   1.7.0 テイク名フォールバック、全角表記・音名後の♯/♭対応、解析の進捗表示とキャンセル、
--         ファイル名の拡張子判定を改善。ReaPack配布とテストを追加。
--   1.6 元音声のセント補正、Soloistサブモード維持、失敗時のロールバックを追加。
-- @about
--   素材名 り_D4_30.wav などから音名を読み、入力した音へ移調します。
--   MIDIエディタの選択ノートから、目標音を自動入力できます。
--   チェック時のみ元音声を解析してセント補正。チェック状態を保存します。
--   時間選択がある場合は、その範囲だけを解析します。
--   解析結果には検出フレーム数と確信度を表示します。
--   ファイル名に音名がない場合は、テイク名から読み取ります。
--   選択アイテムのアクティブテイクのみ対象。外部拡張は不要です。
--   元の音声ファイルを書き換えず、テイクの設定を変更します。

-- 連続作業で完了ダイアログが不要なら false に変更できます。
local SHOW_SUCCESS_MESSAGE = true

-- ファイル名に音名がないとき、テイク名も読みます。
-- 意図しないテイク名で誤検出する場合は false にしてください。
local READ_TAKE_NAME = true

local TITLE = "人力：ファイル名から音程合わせ"
local STATE_SECTION = "Jinriki_FilenamePitch_Soloist_v1"
local NOTE_OFFSETS = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }
local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local MAX_REPORT_ROWS = 16
local MAX_NOTE_LENGTH = 24

-- 音名として扱う拡張子だけを取り除きます。foo.A4 のような名前を
-- 「A4という拡張子」と誤認しないようにするためです。
local AUDIO_EXTENSIONS = {
  wav = true, wave = true, aif = true, aiff = true, mp3 = true, flac = true,
  ogg = true, opus = true, m4a = true, aac = true, wv = true, ape = true,
  caf = true, w64 = true, bwf = true, wem = true, wma = true, mp2 = true,
  amb = true, au = true, snd = true, rf64 = true, oga = true, mka = true,
}

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 日本語環境で入力・保存されやすい表記ゆれを半角へ寄せます。
-- 全角ASCII（Ａ〜Ｚ、０〜９、＃、（）など）はU+FF01〜U+FF5Eに並んでいるため、
-- utf8.char が使える環境ではまとめて変換します。
local SYMBOL_MAP = {
  ["♯"] = "#", ["♭"] = "b",
  ["＃"] = "#",
  ["－"] = "-", ["−"] = "-", ["‐"] = "-", ["–"] = "-", ["—"] = "-",
  ["　"] = " ",
  ["＿"] = "_", ["（"] = "(", ["）"] = ")", ["［"] = "[", ["］"] = "]",
  ["【"] = "[", ["】"] = "]", ["｛"] = "{", ["｝"] = "}",
  ["．"] = ".", ["・"] = ".", ["，"] = ",", ["："] = ":", ["／"] = "/",
}
if utf8 and utf8.char then
  for code = 0x21, 0x7E do
    SYMBOL_MAP[utf8.char(code + 0xFEE0)] = string.char(code)
  end
end

local function normalize_symbols(text)
  for from, to in pairs(SYMBOL_MAP) do
    -- 置換先を関数で返し、%などのパターン特殊文字を安全に扱います。
    text = text:gsub(from, function() return to end)
  end
  return text
end

local function parse_note(text)
  text = normalize_symbols(trim(text)):gsub("%s+", "")
  -- C#4 と C4# の両方を受け付けます。
  local letter, accidental, octave_text = text:match("^([A-Ga-g])([#bB]?)(%-?%d+)$")
  if not letter then
    letter, octave_text, accidental = text:match("^([A-Ga-g])(%-?%d+)([#bB]?)$")
  end
  if not letter then return nil end
  letter = letter:upper()
  accidental = accidental:lower()
  local octave = tonumber(octave_text)
  if not octave or octave < -1 or octave > 9 then return nil end
  local offset = accidental == "#" and 1 or (accidental == "b" and -1 or 0)
  local note = (octave + 1) * 12 + NOTE_OFFSETS[letter] + offset
  if note < 0 or note > 127 then return nil end
  return note, letter .. accidental .. tostring(octave)
end

local function midi_note_name(pitch)
  return NOTE_NAMES[pitch % 12 + 1] .. tostring(math.floor(pitch / 12) - 1)
end

local function selected_midi_target(project)
  local editor = reaper.MIDIEditor_GetActive()
  if not editor then return nil end
  local active_take = reaper.MIDIEditor_GetTake(editor)
  if not active_take or not reaper.ValidatePtr2(project, active_take, "MediaItem_Take*")
    or not reaper.TakeIsMIDI(active_take) then
    return nil, "MIDI：参照不可／手入力", true
  end

  -- 同じエディタで複数のテイクを編集している場合も選択ノートを確認します。
  local takes, take_index = {}, 0
  while true do
    local take = reaper.MIDIEditor_EnumTakes(editor, take_index, true)
    if not take then break end
    if not reaper.ValidatePtr2(project, take, "MediaItem_Take*") or not reaper.TakeIsMIDI(take) then
      return nil, "MIDI：参照不可／手入力", true
    end
    takes[#takes + 1] = take
    take_index = take_index + 1
  end
  if #takes == 0 then takes[1] = active_take end

  local target
  for _, take in ipairs(takes) do
    local note_index = -1
    while true do
      note_index = reaper.MIDI_EnumSelNotes(take, note_index)
      if note_index < 0 then break end
      local ok, selected, _, _, _, _, pitch = reaper.MIDI_GetNote(take, note_index)
      if not ok or not selected or not pitch or pitch < 0 or pitch > 127 or pitch % 1 ~= 0 then
        return nil, "MIDI：読取不可／手入力", true
      end
      if target ~= nil and target ~= pitch then
        return nil, "MIDI：複数音程／手入力", true
      end
      target = pitch
    end
  end
  if target == nil then return nil, "MIDI：未選択／手入力", false end
  return target, "MIDIから自動入力", false
end

local function basename(path)
  return path:match("([^/\\]+)$") or path
end

-- 音声ファイルの拡張子だけを取り除きます。foo.A4 の「.A4」は残します。
local function strip_audio_extension(name)
  return (name:gsub("%.([%w]+)$", function(extension)
    if AUDIO_EXTENSIONS[extension:lower()] then return "" end
    return "." .. extension
  end))
end

local function note_from_text(text, kind)
  kind = kind or "ファイル名"
  local stem = normalize_symbols(strip_audio_extension(basename(text)))
  local found, seen, position = {}, {}, 1
  while true do
    -- C#4 と C4# の両方を受け付けます。音名の前後が英数字の場合は
    -- 英単語や連番の一部とみなして除外します（日本語は区切りとみなします）。
    local first, last, token = stem:find("([A-Ga-g][#bB]?%-?%d+[#bB]?)", position)
    if not first then break end
    position = last + 1
    local before = stem:sub(first - 1, first - 1)
    local after = stem:sub(last + 1, last + 1)
    -- ロケールに依存しないよう、ASCIIの英数字だけを連続文字とみなします。
    if not before:match("^[A-Za-z0-9]$") and not after:match("^[A-Za-z0-9]$") then
      local note, label = parse_note(token)
      if note and not seen[note] then
        seen[note] = true
        found[#found + 1] = { note = note, label = label }
      end
    end
  end
  if #found == 0 then
    return nil, nil, kind .. "から音名を読めません", "none"
  end
  if #found > 1 then
    local labels = {}
    for _, candidate in ipairs(found) do labels[#labels + 1] = candidate.label end
    return nil, nil, kind .. "に音名が複数あります（" .. table.concat(labels, " / ")
      .. "）", "multiple"
  end
  return found[1].note, found[1].label, nil, "ok"
end

local function note_from_filename(filename)
  return note_from_text(filename, "ファイル名")
end

local function note_from_take_name(name)
  return note_from_text(name, "テイク名")
end

local function source_filename(take)
  local source = reaper.GetMediaItemTake_Source(take)
  local visited = {}
  while source and not visited[source] do
    visited[source] = true
    local parent = reaper.GetMediaSourceParent(source)
    if not parent then
      return reaper.GetMediaSourceFileName(source) or ""
    end
    source = parent
  end
  return ""
end

-- アイテム内の再生範囲を、元ソース上の[start, span]へ変換します。
-- ループ素材は既存どおり、選択区内で長い方のループ区間を使います。
local function source_range(source_length, offset, duration, loop)
  if source_length <= 0 or duration <= 0 then return nil, 0 end
  if loop then
    offset = offset % source_length
    local first = math.min(duration, source_length - offset)
    local second = math.min(math.max(0, duration - first), source_length)
    if second > first then return 0, second end
    return offset, first
  end
  local start = math.max(0, offset)
  return start, math.max(0, math.min(source_length, offset + duration) - start)
end

-- タイムラインの時間選択とアイテムの再生範囲を交差させます。
-- 時間選択がない場合は、アイテム全体と limited=false を返します。
local function intersect_time_selection(item_position, item_length,
                                        selection_start, selection_end)
  local item_end = item_position + item_length
  if not selection_start or not selection_end or selection_end <= selection_start then
    return item_position, item_end, false
  end
  local play_start = math.max(item_position, selection_start)
  local play_end = math.min(item_end, selection_end)
  if play_end <= play_start then return nil end
  return play_start, play_end, true
end

-- Native-rate source peaks return individual PCM samples. Reading the source
-- avoids take pitch, time-stretching, volume and FX affecting the estimate.
local function median(values)
  local copy = {}
  for index, value in ipairs(values) do copy[index] = value end
  table.sort(copy)
  local middle = math.floor((#copy + 1) / 2)
  if #copy % 2 == 1 then return copy[middle] end
  return (copy[middle] + copy[middle + 1]) / 2
end

local function frame_pitch(samples, sample_rate, expected, short)
  -- The filename provides a period estimate. Avoid requiring the long lag
  -- needed for the lowest supported voice when analyzing a much higher note.
  -- Include shorter periods so octave-up/mislabeled samples are still rejected.
  local min_lag = math.max(2, math.floor(sample_rate / math.min(5000, expected * 4)))
  local max_lag = math.ceil(sample_rate / (expected / 1.6))
  local window = #samples - max_lag
  if window < math.max(24, math.ceil(sample_rate / expected * 2)) then return nil end
  local sum, square = 0, 0
  for _, value in ipairs(samples) do sum = sum + value; square = square + value * value end
  local rms = math.sqrt(math.max(0, square / #samples - (sum / #samples) ^ 2))
  if rms < 0.0005 then return nil end
  local normalized, running = {}, 0
  for lag = 1, max_lag do
    local value = 0
    for index = 1, window do
      local delta = samples[index] - samples[index + lag]
      value = value + delta * delta
    end
    running = running + value
    normalized[lag] = running > 0 and value * lag / running or 1
  end
  local lag, first, fundamental = min_lag, nil, nil
  while lag < max_lag do
    if normalized[lag] < (short and 0.10 or 0.15) then
      while lag < max_lag - 1 and normalized[lag + 1] < normalized[lag] do lag = lag + 1 end
      if lag <= min_lag or lag >= max_lag then return nil end
      local left, center, right = normalized[lag - 1], normalized[lag], normalized[lag + 1]
      local denominator = 2 * (left - 2 * center + right)
      local offset = denominator ~= 0 and (left - right) / denominator or 0
      offset = math.max(-0.5, math.min(0.5, offset))
      local frequency = sample_rate / (lag + offset)
      -- Compare interpolated valley depths as well as periods. Otherwise a
      -- high note's coarse sample grid can make its fundamental look worse.
      local depth = math.max(0, center + 0.25 * (right - left) * offset)
      local candidate = { frequency = frequency, confidence = 1 - depth }
      if not first then first = candidate end
      local cents = 1200 * math.log(frequency / expected) / math.log(2)
      if math.abs(cents) <= 200 and (not fundamental or candidate.confidence > fundamental.confidence) then
        fundamental = candidate
      end
    end
    lag = lag + 1
  end
  if not first then return nil end
  -- A strong even harmonic can satisfy the first YIN threshold before the
  -- fundamental. Prefer the expected-period valley only when the waveform
  -- supports it substantially better; a true octave-up sine must stay up.
  if fundamental and fundamental.confidence >= 0.90 and fundamental.confidence >= first.confidence + 0.035 then
    local ratio = first.frequency / fundamental.frequency
    for _, harmonic in ipairs({2, 3}) do
      if math.abs(1200 * math.log(ratio / harmonic) / math.log(2)) <= 45 then
        first = fundamental; break
      end
    end
  end
  return first.frequency, rms, first.confidence
end

local function choose_estimate(observations, span, expected, hop)
  local loudest, overall = 0, 0
  for _, candidate in ipairs(observations) do
    overall = math.max(overall, candidate.rms)
    if math.abs(candidate.cents) <= 50 then loudest = math.max(loudest, candidate.rms) end
  end
  local voiced, values = {}, {}
  local confidence_sum = 0
  for _, candidate in ipairs(observations) do
    if math.abs(candidate.cents) <= 50 and candidate.rms >= loudest * 0.15 then
      voiced[#voiced + 1] = candidate
      values[#values + 1] = candidate.cents
      confidence_sum = confidence_sum + candidate.confidence
    end
  end
  -- 画面表示用の品質。frames は「音程が取れたフレーム数」で、
  -- 解析した全フレーム数ではありません。
  local quality = {
    frames = #observations,
    voiced = #voiced,
    voiced_ratio = #observations > 0 and #voiced / #observations or 0,
    confidence = #voiced > 0 and confidence_sum / #voiced or 0,
  }

  -- Keep out-of-range estimates too: their count alone cannot distinguish
  -- a transient/harmonic detection from a genuinely sustained second pitch.
  -- Require a consecutive, periodic, sufficiently loud plateau as evidence.
  local gap = math.max(0.008, hop * 1.8)
  local clusters = {}
  local level = (loudest > 0 and loudest or overall) * 0.35
  for first = 1, #observations do
    local start = observations[first]
    local low, high, previous = start.cents, start.cents, start.time
    local cluster_values, levels, cluster = {}, {}, nil
    for last = first, #observations do
      local candidate = observations[last]
      if candidate.confidence < 0.9 or candidate.rms < level
        or (last > first and candidate.time - previous > gap) then break end
      low, high = math.min(low, candidate.cents), math.max(high, candidate.cents)
      if high - low > 15 then break end
      cluster_values[#cluster_values + 1] = candidate.cents
      levels[#levels + 1] = candidate.rms
      previous = candidate.time
      if #cluster_values >= 3 then
        cluster = { cents = median(cluster_values), width = candidate.time - start.time,
          low = low, high = high, rms = median(levels) }
      end
    end
    if cluster then clusters[#clusters + 1] = cluster end
  end

  local function competing_pitch(cents)
    -- Short onset fragments are tolerated. Two sustained plateaus remain
    -- ambiguous even if one is outside the filename's +/-50-cent window.
    local required = math.max(2 / expected, math.min(0.05, span * 0.25))
    for _, cluster in ipairs(clusters) do
      if cluster.width >= required and math.abs(cluster.cents - cents) > 20 then
        return string.format("別の音程の安定区間もあるため補正なし（推定 %+0.0f／%+0.0f cent）", cents, cluster.cents)
      end
    end
  end

  if #values >= 3 then
    local center, deviations, inliers = median(values), {}, {}
    local consecutive, longest, previous = 0, 0, nil
    for _, candidate in ipairs(voiced) do
      local delta = math.abs(candidate.cents - center)
      deviations[#deviations + 1] = delta
      if delta <= 15 then
        inliers[#inliers + 1] = candidate.cents
        consecutive = previous and candidate.time - previous <= gap and consecutive + 1 or 1
        longest = math.max(longest, consecutive)
        previous = candidate.time
      else consecutive, previous = 0, nil end
    end
    if median(deviations) <= 8 and #inliers >= math.max(3, math.ceil(#values * 0.75)) and longest >= 3 then
      local cents = median(inliers)
      local conflict = competing_pitch(cents)
      if conflict then return nil, nil, conflict, true, quality end
      return cents, #inliers < #observations and "一時的な推定の外れを除外／" or "",
        nil, false, quality
    end
  end

  -- A brief voiced tail may only provide two distinct windows. Require very
  -- strong periodicity and close agreement instead of lowering all thresholds.
  if span < 0.08 and #voiced == 2 then
    local first, second = voiced[1], voiced[2]
    if first.confidence >= 0.97 and second.confidence >= 0.97
      and math.abs(first.cents - second.cents) <= 3
      and math.abs(first.time - second.time) >= 0.5 / expected then
      local cents = (first.cents + second.cents) / 2
      local conflict = competing_pitch(cents)
      if conflict then return nil, nil, conflict, true, quality end
      return cents, "短い有声区間を使用／", nil, false, quality
    end
  end

  -- Speech vowels need not be perfectly flat: use a sustained, narrow band
  -- rather than requiring a near-sine plateau. Competing bands still veto it.
  local required = math.max(0.05, 8 / expected)
  local best
  for _, cluster in ipairs(clusters) do
    if cluster.low >= -50 and cluster.high <= 50 and cluster.width >= required
      and (not best or cluster.width > best.width) then best = cluster end
  end
  if best then
    local conflict = competing_pitch(best.cents)
    if conflict then return nil, nil, conflict, true, quality end
    return best.cents, string.format("安定した母音区間を使用（約%.0f ms）／", best.width * 1000),
      nil, false, quality
  end
  if #voiced < 3 then
    local reason = #observations > #voiced
      and string.format("音名から±50 cent以内の安定区間が不足したため補正なし（範囲内 %d/%d 区間）", #voiced, #observations)
      or "安定した有声音を検出できないため補正なし"
    return nil, nil, reason, false, quality
  end
  return nil, nil, "音程の揺れが大きく安定区間を選べないため補正なし", false, quality
end

local function analyze_source(entry, progress)
  local take, item = entry.take, entry.item
  if not reaper.APIExists("PCM_Source_GetPeaks") then
    return nil, "このREAPERでは音声解析APIが利用できないため補正なし"
  end
  if reaper.GetTakeNumStretchMarkers(take) > 0 then
    return nil, "ストレッチマーカーがあるため補正なし"
  end
  local source = reaper.GetMediaItemTake_Source(take)
  if not source then return nil, "音声ソースを取得できないため補正なし" end
  local sample_rate = reaper.GetMediaSourceSampleRate(source)
  local channels = reaper.GetMediaSourceNumChannels(source)
  local source_length, beats = reaper.GetMediaSourceLength(source)
  if beats or sample_rate < 8000 or sample_rate > 384000 or channels < 1 or channels > 64 then
    return nil, "この音声形式は解析できないため補正なし"
  end
  local expected = 440 * 2 ^ ((entry.source_note - 69) / 12)
  if expected < 70 or expected > 1100 then
    return nil, "解析範囲（70〜1100 Hz）外のため補正なし"
  end
  local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local play_start = entry.analysis_play_start or item_position
  local play_end = entry.analysis_play_end or (item_position + item_length)
  if rate <= 0 or source_length <= 0 or play_end <= play_start then
    return nil, "解析範囲がないため補正なし"
  end
  local duration = (play_end - play_start) * rate
  local source_offset = offset + (play_start - item_position) * rate
  local start, span = source_range(source_length, source_offset, duration,
    reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") ~= 0)
  if not start then return nil, "解析範囲がないため補正なし" end
  -- At least 4.5 expected periods, with a small absolute floor. For D4 this
  -- permits roughly 16 ms instead of rejecting everything below 80 ms.
  local minimum_span = math.max(0.012, 4.5 / expected)
  if span < minimum_span then
    return nil, string.format("この音程の解析に必要な約%.0f msが不足したため補正なし", minimum_span * 1000)
  end

  local stride = math.max(1, math.floor(sample_rate / 12000))
  local analysis_rate = sample_rate / stride
  local function read_pass(frame_span, cap)
  local count = math.floor(analysis_rate * frame_span)
  local raw_count = count * stride
  -- Stay on native sample boundaries and leave a small decoder edge margin.
  local first_sample = math.ceil(start * sample_rate) + 2
  local last_start = math.floor((start + span) * sample_rate) - raw_count - 2
  if last_start < first_sample then return nil, nil, "解析できる音声が短いため補正なし" end
  local frame_duration = raw_count / sample_rate
  local frames = math.min(cap, math.max(3, math.floor((span - frame_duration) / math.max(0.002, frame_duration * 0.2)) + 1))
  local buffer = reaper.new_array(raw_count * channels * 2)
  local observations = {}
  local channel_mode = reaper.GetMediaItemTakeInfo_Value(take, "I_CHANMODE")
  for frame = 1, frames do
    progress(frame, frames)
    local time = (first_sample + math.floor((last_start - first_sample) * (frame - 1) / (frames - 1))) / sample_rate
    -- REAPER's array/output APIs run on the main Lua stack. The worker yields
    -- this read request to the UI loop, then receives ordinary Lua samples.
    local result, pcm = coroutine.yield(function()
      buffer.clear()
      local returned = reaper.PCM_Source_GetPeaks(source, sample_rate, time, channels, raw_count, 0, buffer)
      return returned, buffer.table()
    end)
    if not result or (result & 0xfffff) < raw_count then
      return nil, nil, "元音声のサンプルを取得できないため補正なし"
    end
    -- Coarse peak data is unsuitable for cent measurement; fail closed.
    local block = raw_count * channels
    for index = 1, block, math.max(1, math.floor(block / 64)) do
      if math.abs(pcm[index] - pcm[block + index]) > 0.0000001 then
        return nil, nil, "元音声を十分な精度で取得できないため補正なし"
      end
    end
    local chosen, maximum = 1, -1
    for channel = 1, channels do
      if (channel_mode ~= 3 or channel == 1) and (channel_mode ~= 4 or channel == math.min(2, channels)) then
        local energy = 0
        for index = channel, block, channels do energy = energy + pcm[index] ^ 2 end
        if energy > maximum then maximum, chosen = energy, channel end
      end
    end
    local samples = {}
    for index = 1, count do
      local value = 0
      for step = 0, stride - 1 do
        value = value + pcm[((index - 1) * stride + step) * channels + chosen]
      end
      samples[index] = value / stride
    end
    local frequency, rms, confidence = frame_pitch(samples, analysis_rate, expected, span < 0.08)
    if frequency then
      local cents = 1200 * math.log(frequency / expected) / math.log(2)
      observations[#observations + 1] = { cents = cents, rms = rms, confidence = confidence, time = time + frame_duration / 2 }
    end
    coroutine.yield()
  end
  return observations, (last_start - first_sample) / sample_rate / (frames - 1)
  end
  local function quality_text(quality)
    if not quality or quality.frames == 0 then return "" end
    return string.format("検出 %d/%d・確信度 %.2f",
      quality.voiced, quality.frames, quality.confidence)
  end
  local failure
  for pass, window in ipairs({math.max(0.018, 6 / expected), math.max(0.010, 4 / expected)}) do
    local observations, hop, problem = read_pass(math.min(window, span * 0.85), pass == 1 and 96 or 128)
    if not observations then return nil, problem end
    local cents, description, reason, conflict, quality =
      choose_estimate(observations, span, expected, hop)
    if cents then
      local rounded = math.floor(math.abs(cents) * 10 + 0.5) / 10
      if cents < 0 then rounded = -rounded end
      local text = description .. string.format(
        "実音のずれ %+0.1f cent／補正 %+0.1f cent", rounded, -rounded)
      local quality_note = quality_text(quality)
      if quality_note ~= "" then text = text .. "／" .. quality_note end
      return -rounded / 100, text
    end
    local quality_note = quality_text(quality)
    if quality_note ~= "" then reason = reason .. "／" .. quality_note end
    if conflict then return nil, reason end
    failure = reason
  end
  return nil, failure
end

local function show_pitch_dialog(default, title, on_submit, initial_status)
  local text, caret, selected_all = default, #default, true
  local checked = reaper.GetExtState(STATE_SECTION, "analyze_audio") == "1"
  local focus, status, worker, closed, previous_mouse = 0, initial_status or "", nil, false, false
  local progress_fraction = 0
  local reply = table.pack()
  local function close()
    if not closed then closed = true; gfx.quit() end
  end
  reaper.atexit(close)
  gfx.init(title, 600, 320, 0)
  local function remember()
    reaper.SetExtState(STATE_SECTION, "analyze_audio", checked and "1" or "0", true)
  end
  local function toggle() checked = not checked; remember() end
  local function submit()
    local note, label = parse_note(text)
    if not note then status = "音名＋オクターブで入力してください（例 E4 / F#3）。"; focus = 0; return end
    remember()
    progress_fraction = 0
    worker = coroutine.create(function()
      return on_submit(note, label, checked, function(message, fraction)
        status = message
        if fraction then
          progress_fraction = math.max(0, math.min(1, fraction))
        end
      end)
    end)
  end
  local function replace(fragment)
    local prefix = selected_all and "" or text:sub(1, caret)
    local suffix = selected_all and "" or text:sub(caret + 1)
    local next_text = prefix .. fragment .. suffix
    if #next_text > MAX_NOTE_LENGTH then return end
    text, caret, selected_all = next_text, #prefix + #fragment, false
    status = ""
  end
  local function draw()
    gfx.set(0.09, 0.105, 0.13, 1); gfx.rect(0, 0, gfx.w, gfx.h, true)
    local function label(x, y, value, size, r, g, b)
      gfx.setfont(1, "Yu Gothic UI", size)
      gfx.set(r or 0.9, g or 0.92, b or 0.95, 1); gfx.x, gfx.y = x, y; gfx.drawstr(value, 0, gfx.w - 20, gfx.h)
    end
    label(32, 20, "合わせたい音程", 20)
    label(300, 24, "例：G3 / F#3 / Bb2", 15, 0.6, 0.65, 0.72)
    gfx.set(0.15, 0.18, 0.23, 1); gfx.rect(32, 60, gfx.w - 64, 48, true)
    gfx.set(focus == 0 and 0.35 or 0.3, focus == 0 and 0.7 or 0.35, focus == 0 and 1 or 0.43, 1)
    gfx.rect(32, 60, gfx.w - 64, 48, false)
    gfx.setfont(1, "Yu Gothic UI", 24)
    if selected_all and focus == 0 and not worker then
      local width = gfx.measurestr(text)
      gfx.set(0.16, 0.38, 0.62, 1); gfx.rect(42, 68, width + 4, 30, true)
    end
    label(44, 68, text, 24)
    if focus == 0 and not selected_all and not worker then
      local width = gfx.measurestr(text:sub(1, caret))
      gfx.set(0.9, 0.94, 1, 1); gfx.line(44 + width, 70, 44 + width, 97)
    end
    gfx.set(0.18, 0.23, 0.3, 1); gfx.rect(32, 136, 22, 22, true)
    gfx.set(focus == 1 and 0.35 or 0.55, focus == 1 and 0.7 or 0.6, 0.9, 1)
    gfx.rect(32, 136, 22, 22, false)
    if checked then
      gfx.set(0.4, 0.85, 1, 1); gfx.line(37, 146, 42, 152); gfx.line(42, 152, 50, 141)
    end
    label(66, 133, "音声を解析してセント補正する", 18)
    label(32, 171, "チェック状態は次回の実行にも引き継ぎます。", 14, 0.6, 0.65, 0.72)
    label(32, 198, status ~= "" and status or "解析できない素材は、補正なしで移調します。", 14, 0.8, 0.8, 0.72)
    if worker then
      local bar_y, bar_width = 224, gfx.w - 64
      gfx.set(0.12, 0.15, 0.2, 1); gfx.rect(32, bar_y, bar_width, 8, true)
      gfx.set(0.33, 0.72, 0.95, 1)
      gfx.rect(32, bar_y, bar_width * progress_fraction, 8, true)
    end
    local apply_x, cancel_x = gfx.w - 248, gfx.w - 128
    gfx.set(0.16, 0.39, 0.59, 1); gfx.rect(apply_x, 252, 104, 38, true)
    gfx.set(0.22, 0.25, 0.3, 1); gfx.rect(cancel_x, 252, 96, 38, true)
    if focus == 2 or focus == 3 then
      gfx.set(0.4, 0.8, 1, 1); gfx.rect(focus == 2 and apply_x or cancel_x, 252, focus == 2 and 104 or 96, 38, false)
    end
    local apply_text = worker and string.format("解析中 %d%%", math.floor(progress_fraction * 100 + 0.5)) or "適用"
    gfx.setfont(1, "Yu Gothic UI", 17)
    local apply_width = gfx.measurestr(apply_text)
    label(apply_x + (104 - apply_width) / 2, 257, apply_text, 17)
    local cancel_width = gfx.measurestr("キャンセル")
    label(cancel_x + (96 - cancel_width) / 2, 257, "キャンセル", 17)
    gfx.update()
  end
  local function loop()
    if closed then return end
    local ok, problem = xpcall(function()
      draw()
      local key = gfx.getchar()
      if key == -1 or key == 27 then close(); return end
      local down = (gfx.mouse_cap & 1) ~= 0
      local click = down and not previous_mouse
      previous_mouse = down
      if worker then
        if click and gfx.mouse_x >= gfx.w - 128 and gfx.mouse_x <= gfx.w - 32
          and gfx.mouse_y >= 252 and gfx.mouse_y <= 290 then close(); return end
        local deadline = reaper.time_precise() + 0.012
        repeat
          local resumed, action = coroutine.resume(worker, table.unpack(reply, 1, reply.n))
          reply = table.pack()
          if not resumed then error(action, 0) end
          if coroutine.status(worker) == "dead" then
            close()
            if action then action() end
            return
          end
          if type(action) == "function" then reply = table.pack(action()) end
        until reaper.time_precise() >= deadline
      else
        if click then
          local x, y = gfx.mouse_x, gfx.mouse_y
          if x >= 32 and x <= gfx.w - 32 and y >= 60 and y <= 108 then
            focus, selected_all, caret = 0, true, #text
          elseif x >= 32 and x <= gfx.w - 32 and y >= 128 and y <= 165 then
            focus = 1; toggle()
          elseif y >= 252 and y <= 290 then
            if x >= gfx.w - 248 and x <= gfx.w - 144 then submit()
            elseif x >= gfx.w - 128 and x <= gfx.w - 32 then close(); return end
          end
        end
        if key == 9 then focus = (focus + ((gfx.mouse_cap & 8) ~= 0 and 3 or 1)) % 4
        elseif key == 13 then if focus == 3 then close(); return else submit() end
        elseif key == 32 and focus == 1 then toggle()
        elseif key == 32 and focus == 2 then submit()
        elseif key == 32 and focus == 3 then close(); return
        elseif focus == 0 then
          if key == 1 then selected_all = true
          elseif key == 8 then
            if selected_all then text, caret, selected_all = "", 0, false
            elseif caret > 0 then text = text:sub(1, caret - 1) .. text:sub(caret + 1); caret = caret - 1 end
          elseif key == 6579564 then
            if selected_all then text, caret, selected_all = "", 0, false
            else text = text:sub(1, caret) .. text:sub(caret + 2) end
          elseif key == 1818584692 then caret, selected_all = math.max(0, caret - 1), false
          elseif key == 1919379572 then caret, selected_all = math.min(#text, caret + 1), false
          elseif key == 1752132965 then caret, selected_all = 0, false
          elseif key == 6647396 then caret, selected_all = #text, false
          elseif key == 9839 or key == (117 << 24) + 9839 then replace("#")
          elseif key == 9837 or key == (117 << 24) + 9837 then replace("b")
          elseif key >= 32 and key <= 126 and (gfx.mouse_cap & 4) == 0 then replace(string.char(key))
          end
        end
      end
      if not closed then reaper.defer(loop) end
    end, debug.traceback)
    if not ok then close(); reaper.ShowMessageBox("処理に失敗しました。\n\n" .. tostring(problem), TITLE, 0) end
  end
  reaper.defer(loop)
end

local function version_parts(name)
  local parts = {}
  for number in (name:match("%d[%d%.]*") or "0"):gmatch("%d+") do
    parts[#parts + 1] = tonumber(number)
  end
  return parts
end

local function newer_version(left, right)
  for index = 1, math.max(#left, #right) do
    local a, b = left[index] or 0, right[index] or 0
    if a ~= b then return a > b end
  end
  return false
end

local function pitch_mode_names()
  local names, index = {}, 0
  while true do
    local exists, name = reaper.EnumPitchShiftModes(index)
    if not exists then break end
    -- Unsupported slots may still return true with a nil/empty name.
    if name and name ~= "" then names[#names + 1] = name end
    index = index + 1
  end
  return names
end

local function find_soloist()
  local best
  local index = 0
  while true do
    local exists, name = reaper.EnumPitchShiftModes(index)
    if not exists then break end
    if name and name:lower():find("soloist", 1, true) then
      local version = version_parts(name)
      if not best or newer_version(version, best.version) then
        best = { index = index, name = name, version = version }
      end
    end
    index = index + 1
  end
  return best
end

local function read_settings(take)
  return {
    pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH"),
    mode = reaper.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE"),
    preserve = reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH")
  }
end

local function matches(take, settings)
  local actual = read_settings(take)
  return math.abs(actual.pitch - settings.pitch) < 0.0000001
    and actual.mode == settings.mode and actual.preserve == settings.preserve
end

local function write_settings(take, settings)
  for _, field in ipairs({
    { "I_PITCHMODE", settings.mode },
    { "B_PPITCH", settings.preserve },
    { "D_PITCH", settings.pitch }
  }) do
    if not reaper.SetMediaItemTakeInfo_Value(take, field[1], field[2]) then
      error("テイクの設定を変更できませんでした（" .. field[1] .. "）。", 0)
    end
  end
  if not matches(take, settings) then
    error("設定後の値が指定値と一致しませんでした。", 0)
  end
end

local function report_rows(rows)
  local text = {}
  for index = 1, math.min(#rows, MAX_REPORT_ROWS) do
    text[#text + 1] = rows[index]
  end
  if #rows > MAX_REPORT_ROWS then
    text[#text + 1] = string.format("…ほか %d 件", #rows - MAX_REPORT_ROWS)
  end
  return table.concat(text, "\n")
end

local function apply_entries(project, entries, skipped, soloist, target_note, target_label, analyze)
  local changes, details = {}, {}
  for _, entry in ipairs(entries) do
    entry.old = read_settings(entry.take)
    local pitch = target_note - entry.source_note + (entry.correction or 0)
    local base_mode = soloist.index * 65536
    -- 同じSoloistの詳細設定は維持。それ以外からの切替時は詳細設定0。
    local submode = 0
    if entry.old.mode >= 0 and math.floor(entry.old.mode / 65536) == soloist.index then
      submode = entry.old.mode % 65536
    end
    entry.new = { pitch = pitch, mode = base_mode + submode, preserve = 1 }
    if not matches(entry.take, entry.new) then changes[#changes + 1] = entry end
    local name_note = entry.name_source == "テイク名" and "（テイク名）" or ""
    details[#details + 1] = string.format("%s%s：%s → %s（%+.3f 半音）",
      entry.filename, name_note, entry.source_label, target_label, pitch)
    if entry.analysis_limited and entry.analysis_play_start then
      details[#details + 1] = string.format("  解析範囲：%.3f〜%.3f 秒",
        entry.analysis_play_start, entry.analysis_play_end)
    end
    if entry.analysis_status then details[#details + 1] = "  " .. entry.analysis_status end
  end

  if #changes > 0 then
    reaper.Undo_BeginBlock2(project)
    reaper.PreventUIRefresh(1)
    local touched = {}
    local succeeded, problem = xpcall(function()
      for _, entry in ipairs(changes) do
        touched[#touched + 1] = entry
        write_settings(entry.take, entry.new)
      end
    end, function(message) return tostring(message) end)

    local restored = true
    if not succeeded then
      -- 失敗した項目も含め、この実行で触れた設定をすべて戻します。
      for index = #touched, 1, -1 do
        local entry = touched[index]
        for _, field in ipairs({
          { "D_PITCH", entry.old.pitch }, { "I_PITCHMODE", entry.old.mode },
          { "B_PPITCH", entry.old.preserve }
        }) do
          pcall(reaper.SetMediaItemTakeInfo_Value, entry.take, field[1], field[2])
        end
        local read_ok, equal = pcall(matches, entry.take, entry.old)
        if not read_ok or not equal then restored = false end
      end
    end

    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock2(project, succeeded
      and string.format("人力：%d件を%sへ移調（Soloist）", #changes, target_label)
      or "人力：音程合わせ中のエラー", -1)
    reaper.UpdateArrange()
    if not succeeded then
      local recovery = restored and "今回触れた設定は元に戻しました。"
        or "一部の設定を戻せませんでした。REAPERの「元に戻す」を実行してください。"
      reaper.ShowMessageBox("処理に失敗しました。\n" .. recovery .. "\n\n" .. problem, TITLE, 0)
      return
    end
  end

  -- 前回の入力はREAPERを閉じるまで記憶します。
  reaper.SetExtState(STATE_SECTION, "last_target", target_label, false)
  local analysis_failures = 0
  for _, entry in ipairs(entries) do if entry.analysis_failed then analysis_failures = analysis_failures + 1 end end
  if SHOW_SUCCESS_MESSAGE or #skipped > 0 or #changes == 0 or analysis_failures > 0 then
    local summary = string.format("%d 件を変更しました（対象 %d 件）。\n音程：%s\nモード：%s\n",
      #changes, #entries, target_label, soloist.name)
    if analyze then
      summary = summary .. string.format("セント補正：%d 件成功／%d 件は補正なし\n", #entries - analysis_failures, analysis_failures)
    else summary = summary .. "音声解析：オフ\n" end
    if #changes == 0 then summary = summary .. "すでに指定の設定になっています。\n" end
    summary = summary .. "\n" .. report_rows(details)
    if #skipped > 0 then
      summary = summary .. string.format("\n\nスキップ %d 件：\n", #skipped) .. report_rows(skipped)
    end
    reaper.ShowMessageBox(summary, TITLE, 0)
  end
end

local function read_time_selection(project)
  if reaper.APIExists("GetSet_LoopTimeRange2") then
    return reaper.GetSet_LoopTimeRange2(project, false, false, 0, 0, false)
  end
  return reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
end

local function main()
  -- 変更しない場合の自動Undoを抑制。変更時は自前で1回にまとめます。
  reaper.defer(function() end)
  local project = reaper.EnumProjects(-1, "")
  local count = reaper.CountSelectedMediaItems(project)
  if count == 0 then
    reaper.ShowMessageBox("トラック上の音声アイテムを選択してから実行してください。", TITLE, 0)
    return
  end
  local selection_start, selection_end = read_time_selection(project)
  local has_time_selection = selection_end > selection_start

  local entries, skipped = {}, {}
  for index = 0, count - 1 do
    local item = reaper.GetSelectedMediaItem(project, index)
    local take = reaper.GetActiveTake(item)
    local take_name = take and trim(reaper.GetTakeName(take) or "") or ""
    local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local reason, filename, source_note, source_label, name_source, parse_code
    local analysis_play_start, analysis_play_end, analysis_limited
    if reaper.GetMediaItemInfo_Value(item, "C_LOCK") % 2 == 1 then
      reason = "ロックされています"
    elseif not take then
      reason = "アクティブテイクがありません"
    elseif reaper.TakeIsMIDI(take) then
      reason = "MIDIアイテムです"
    else
      filename = source_filename(take)
      if filename ~= "" then
        source_note, source_label, reason, parse_code = note_from_filename(filename)
      else
        reason, parse_code = "元ファイル名を取得できません", "none"
      end
      -- ファイル名に音名がない場合だけ、テイク名を読みます。
      -- 「音名が複数」の場合は、勝手に選ばずエラーにします。
      if READ_TAKE_NAME and not source_note and parse_code == "none"
        and take_name ~= "" and take_name ~= basename(filename) then
        local take_note, take_note_label, take_reason = note_from_take_name(take_name)
        if take_note then
          source_note, source_label, reason = take_note, take_note_label, nil
          name_source = "テイク名"
        else
          reason = reason .. "／" .. take_reason
        end
      end
      if not reason then
        analysis_play_start, analysis_play_end, analysis_limited =
          intersect_time_selection(item_position, item_length, selection_start, selection_end)
        if not analysis_play_start then
          reason = has_time_selection and "時間選択の範囲外です" or "アイテムの長さがありません"
        end
      end
    end
    if reason then
      local label = filename and filename ~= "" and basename(filename)
        or (take_name ~= "" and take_name) or ("選択項目 " .. (index + 1))
      skipped[#skipped + 1] = label .. "：" .. reason
    else
      entries[#entries + 1] = {
        item = item, take = take,
        filename = filename ~= "" and basename(filename) or "(ファイル名なし)",
        name_source = name_source or "ファイル名",
        source_note = source_note, source_label = source_label,
        analysis_play_start = analysis_play_start,
        analysis_play_end = analysis_play_end,
        analysis_limited = analysis_limited,
        position = item_position,
        length = item_length,
        source = reaper.GetMediaItemTake_Source(take),
        old = read_settings(take)
      }
    end
  end
  if #entries == 0 then
    local message = "処理できる音声アイテムがありません。\n\n" .. report_rows(skipped)
      .. "\n\nファイル名の例：り_D4_30.wav / E3_あ.wav / あ_F#3.wav"
    if has_time_selection then
      message = message .. "\n時間選択の範囲に音声アイテムがあるか確認してください。"
    end
    reaper.ShowMessageBox(message, TITLE, 0)
    return
  end

  local soloist = find_soloist()
  if not soloist then
    local modes = pitch_mode_names()
    local message = "利用できるSoloistモードが見つかりませんでした。\n設定は変更していません。"
    if #modes > 0 then
      message = message .. "\n\n利用可能なピッチシフトモード：\n" .. table.concat(modes, "\n")
    end
    reaper.ShowMessageBox(message, TITLE, 0)
    return
  end

  local default = reaper.GetExtState(STATE_SECTION, "last_target")
  if not parse_note(default) then default = entries[1].source_label end
  local midi_target, midi_status, clear_default = selected_midi_target(project)
  if midi_target ~= nil then
    default = midi_note_name(midi_target)
  elseif clear_default then
    default = ""
  end
  local input_title = string.format("%s（対象 %d 件）", TITLE, #entries)
  if midi_status then input_title = input_title .. " / " .. midi_status end
  local initial_status = ""
  if has_time_selection then
    input_title = input_title .. " / 時間選択"
    initial_status = string.format("時間選択 %.3f〜%.3f 秒の範囲を解析します。",
      selection_start, selection_end)
  end
  local function validate_entries()
    if reaper.EnumProjects(-1, "") ~= project then
      error("プロジェクトが切り替わりました。対象を確認して再実行してください。", 0)
    end
    local current_start, current_end = read_time_selection(project)
    if math.abs(current_start - selection_start) > 1e-9
      or math.abs(current_end - selection_end) > 1e-9 then
      error("時間選択が変わりました。再実行してください。", 0)
    end
    for _, entry in ipairs(entries) do
      if not reaper.ValidatePtr2(project, entry.item, "MediaItem*")
        or not reaper.ValidatePtr2(project, entry.take, "MediaItem_Take*")
        or reaper.GetActiveTake(entry.item) ~= entry.take
        or reaper.GetMediaItemTake_Source(entry.take) ~= entry.source
        or math.abs(reaper.GetMediaItemInfo_Value(entry.item, "D_POSITION") - entry.position) > 1e-9
        or math.abs(reaper.GetMediaItemInfo_Value(entry.item, "D_LENGTH") - entry.length) > 1e-9
        or reaper.GetMediaItemInfo_Value(entry.item, "C_LOCK") % 2 == 1 then
        error("対象アイテムの状態が変わりました。対象を確認して再実行してください。", 0)
      end
    end
  end
  show_pitch_dialog(default, input_title, function(target_note, target_label, analyze, progress)
    validate_entries()
    local project_state = reaper.GetProjectStateChangeCount(project)
    if analyze then
      local total = #entries
      progress("解析を準備中…", 0)
      for index, entry in ipairs(entries) do
        local ok, correction, message = pcall(analyze_source, entry, function(frame, frames)
          validate_entries()
          if reaper.GetProjectStateChangeCount(project) ~= project_state then
            error("解析中にプロジェクトが変更されました。再実行してください。", 0)
          end
          local fraction = ((index - 1) + frame / math.max(1, frames)) / total
          progress(string.format("解析 %d/%d：%s（%d/%d）", index, total, entry.filename, frame, frames),
            fraction)
        end)
        if not ok then
          local problem = tostring(message)
          -- 対象やプロジェクトが変わった場合は、補正なしで続行せず中止します。
          if problem:find("プロジェクトが切り替わりました", 1, true)
            or problem:find("対象アイテムの状態が変わりました", 1, true)
            or problem:find("解析中にプロジェクトが変更されました", 1, true)
            or problem:find("時間選択が変わりました", 1, true) then
            error(problem, 0)
          end
          correction, message = nil, "音声を読み取れないため補正なし"
        end
        entry.correction = correction or 0
        entry.analysis_status = message
        entry.analysis_failed = correction == nil
        progress(string.format("解析 %d/%d：%s", index, total, entry.filename), index / total)
      end
      progress("適用中…", 1)
    end
    return function()
      validate_entries()
      if reaper.GetProjectStateChangeCount(project) ~= project_state then
        error("解析中にプロジェクトが変更されました。設定は変更していません。再実行してください。", 0)
      end
      apply_entries(project, entries, skipped, soloist, target_note, target_label, analyze)
    end
  end, initial_status)
end

-- テストから純粋関数を直接呼ぶための入口です。通常のREAPER実行では
-- この分岐に入らず、main()だけが動きます。
if _G.NAMA_PITCHMATCH_TEST then
  _G.NAMA_PITCHMATCH_TEST_API = {
    trim = trim,
    normalize_symbols = normalize_symbols,
    parse_note = parse_note,
    midi_note_name = midi_note_name,
    basename = basename,
    strip_audio_extension = strip_audio_extension,
    note_from_text = note_from_text,
    note_from_filename = note_from_filename,
    note_from_take_name = note_from_take_name,
    median = median,
    frame_pitch = frame_pitch,
    choose_estimate = choose_estimate,
    version_parts = version_parts,
    newer_version = newer_version,
    report_rows = report_rows,
    read_settings = read_settings,
    matches = matches,
    write_settings = write_settings,
    apply_entries = apply_entries,
    find_soloist = find_soloist,
    pitch_mode_names = pitch_mode_names,
    selected_midi_target = selected_midi_target,
    source_filename = source_filename,
    source_range = source_range,
    intersect_time_selection = intersect_time_selection,
  }
  return
end

main()
