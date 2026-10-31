#!/usr/bin/env python3
r"""Compare the Lua YIN detector with FCPE labels in nama-voices.json.

The benchmark reads the vowel region of each unit, decimates it the same way
the REAPER script does, and runs tools/bench_pitch.lua. FCPE pitch stored in
the JSON is used as the reference, so this tool does not import the AGPL
jinriki_prep code or the ONNX model.

Example:
    python tools/pitch_benchmark.py \
        --json-dir "D:\vst開発\jinriki\vowel-boundaries-fcpe" \
        --rates 8000,12000
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import statistics
import struct
import subprocess
import sys
import tempfile
import wave
from array import array
from pathlib import Path

try:
    import numpy as np
except ImportError:  # pragma: no cover - shown to the user at startup
    np = None

VOWELS = {"a", "i", "u", "e", "o"}
DEFAULT_JSON_DIR = Path(r"D:\vst開発\jinriki\vowel-boundaries-fcpe")
DEFAULT_WAV_DIR = Path(r"D:\vst開発\jinriki")


def read_wav(path: Path):
    """Return (channels, sample_rate) with each channel as a list of floats."""
    with wave.open(str(path), "rb") as wav:
        channels_count = wav.getnchannels()
        width = wav.getsampwidth()
        sample_rate = wav.getframerate()
        frames = wav.getnframes()
        raw = wav.readframes(frames)

    if width == 1:
        values = [(value - 128) / 128.0 for value in raw]
    elif width == 2:
        samples = array("h")
        samples.frombytes(raw)
        if sys.byteorder != "little":
            samples.byteswap()
        values = [value / 32768.0 for value in samples]
    elif width == 3:
        total = len(raw) // 3
        values = [0.0] * total
        for index in range(total):
            base = index * 3
            value = raw[base] | (raw[base + 1] << 8) | (raw[base + 2] << 16)
            if value & 0x800000:
                value -= 0x1000000
            values[index] = value / 8388608.0
    elif width == 4:
        samples = array("i")
        samples.frombytes(raw)
        if sys.byteorder != "little":
            samples.byteswap()
        values = [value / 2147483648.0 for value in samples]
    else:
        raise ValueError(f"未対応のWAVサンプル幅: {width} bytes ({path})")

    channels = [values[channel::channels_count] for channel in range(channels_count)]
    return channels, sample_rate


def select_channel(channels, start: int, end: int, mode: str):
    if mode == "mono" or len(channels) == 1:
        count = end - start
        if len(channels) == 1:
            return channels[0][start:end]
        output = [0.0] * count
        for channel in channels:
            for index in range(count):
                output[index] += channel[start + index]
        scale = 1.0 / len(channels)
        for index in range(count):
            output[index] *= scale
        return output

    best, best_energy = 0, -1.0
    for index, channel in enumerate(channels):
        energy = sum(value * value for value in channel[start:end])
        if energy > best_energy:
            best, best_energy = index, energy
    return channels[best][start:end]


def decimate(samples, native_rate: int, target_rate: int):
    stride = max(1, native_rate // target_rate)
    analysis_rate = native_rate / stride
    count = (len(samples) - stride) // stride + 1
    if count <= 0:
        return [], analysis_rate
    output = [0.0] * count
    for index in range(count):
        base = index * stride
        output[index] = sum(samples[base:base + stride]) / stride
    return output, analysis_rate


def frame_stability(samples, sample_rate: float, reference_hz: float,
                    mad_limit: float, span_limit: float, min_frames: int,
                    ref_offset_limit: float):
    """Classify a region as stable/gliding with an independent autocorrelation.

    This is only a benchmark classifier, not the detector under test. It uses
    40 ms frames with a 10 ms hop and reports:
      - MAD of frame pitch around the region median (cents)
      - 10-90 percentile span (cents)
      - offset of the region median from the FCPE reference (cents)
    """
    if np is None or reference_hz <= 0:
        return None
    x = np.asarray(samples, dtype=np.float64)
    window = max(64, int(sample_rate * 0.040))
    hop = max(16, int(sample_rate * 0.010))
    if len(x) < window:
        return None
    min_lag = max(2, int(sample_rate / 1200.0))
    max_lag = min(window // 2, int(sample_rate / 60.0))
    if max_lag <= min_lag:
        return None
    values = []
    for start in range(0, len(x) - window + 1, hop):
        frame = x[start:start + window]
        frame = frame - frame.mean()
        rms = float(np.sqrt(np.mean(frame * frame)))
        if rms < 0.01:
            continue
        spectrum = np.fft.rfft(frame, n=2 * window)
        correlation = np.fft.irfft(spectrum * np.conj(spectrum))[:window]
        lag = min_lag + int(np.argmax(correlation[min_lag:max_lag]))
        if lag <= 0:
            continue
        hz = sample_rate / lag
        if 60.0 <= hz <= 1200.0:
            values.append(hz)
    if len(values) < min_frames:
        return {"stable": False, "reason": "short", "frames": len(values)}
    cents_values = [1200.0 * math.log2(value / reference_hz) for value in values]
    median = float(np.median(cents_values))
    mad = float(np.median(np.abs(np.asarray(cents_values) - median)))
    p10, p90 = np.percentile(cents_values, [10, 90])
    span = float(p90 - p10)
    if abs(median) > ref_offset_limit:
        reason = "reference-mismatch"
    elif mad > mad_limit or span > span_limit:
        reason = "unstable"
    else:
        reason = "stable"
    return {
        "stable": reason == "stable",
        "reason": reason,
        "frames": len(values),
        "mad": mad,
        "span": span,
        "ref_offset": median,
        "median_hz": reference_hz * (2.0 ** (median / 1200.0)),
    }


def midi_to_hz(midi: float) -> float:
    return 440.0 * (2.0 ** ((midi - 69.0) / 12.0))


def cents(estimated: float, reference: float) -> float:
    return 1200.0 * math.log2(estimated / reference)


def load_cases(json_dir: Path, wav_dir: Path, pattern: str, region: str,
               pad_ms: float, expected_mode: str, min_strength: float,
               max_cases: int | None, verify_hash: bool = True):
    cases = []
    for json_path in sorted(json_dir.glob(pattern)):
        try:
            document = json.loads(json_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"skip {json_path.name}: {error}", file=sys.stderr)
            continue
        source = document.get("source") or {}
        source_path = Path(source.get("path") or "")
        if not source_path.is_absolute():
            source_path = json_dir / source_path
        if not source_path.is_file():
            source_path = wav_dir / source_path.name
        if not source_path.is_file():
            print(f"skip {json_path.name}: WAVが見つかりません ({source_path})", file=sys.stderr)
            continue
        expected_hash = source.get("sha256")
        if verify_hash and expected_hash:
            actual_hash = hashlib.sha256(source_path.read_bytes()).hexdigest()
            if actual_hash.lower() != expected_hash.lower():
                print(f"skip {json_path.name}: WAVのSHA-256がJSONと一致しません",
                      file=sys.stderr)
                continue

        for unit in document.get("units") or []:
            pitch = unit.get("pitch") or {}
            reference_hz = pitch.get("hz")
            reference_midi = pitch.get("midi")
            strength = float(pitch.get("strength") or 0.0)
            if reference_hz is None or reference_midi is None:
                continue
            if strength < min_strength:
                continue

            start = float(unit.get("start") or 0.0)
            end = float(unit.get("end") or 0.0)
            if end <= start:
                continue
            phonemes = (unit.get("phonemes") or "").split()
            starts = unit.get("phoneme_starts") or []
            if starts and phonemes and phonemes[-1] in VOWELS:
                vowel_start = float(starts[-1])
            else:
                vowel_start = start + (end - start) * 0.35

            if region == "unit":
                region_start = start
            else:
                region_start = max(start, vowel_start - pad_ms / 1000.0)
            region_end = end
            if region_end <= region_start:
                continue

            expected_note = int(math.floor(float(reference_midi) + 0.5))
            if expected_mode == "exact":
                expected_hz = float(reference_hz)
            else:
                expected_hz = midi_to_hz(expected_note)

            cases.append({
                "json": json_path,
                "source": source_path,
                "unit_id": str(unit.get("id") or ""),
                "name": str(unit.get("name") or ""),
                "phonemes": " ".join(phonemes),
                "region_start": region_start,
                "region_end": region_end,
                "reference_hz": float(reference_hz),
                "reference_midi": float(reference_midi),
                "expected_note": expected_note,
                "expected_hz": expected_hz,
                "strength": strength,
                "status": "",
                "cents": None,
                "estimated_hz": None,
                "observations": 0,
                "description": "",
            })
            if max_cases and len(cases) >= max_cases:
                return cases
    return cases


def run_rate(cases, rate: int, channel_mode: str, lua: str, timeout: float,
             mad_limit: float, span_limit: float, min_frames: int,
             ref_offset_limit: float):
    helper = Path(__file__).resolve().parent / "bench_pitch.lua"
    repo_root = helper.parent.parent
    by_source = {}
    for case in cases:
        by_source.setdefault(case["source"], []).append(case)

    with tempfile.TemporaryDirectory(prefix="nama-pitch-bench-") as temp:
        temp_dir = Path(temp)
        manifest_path = temp_dir / "manifest.tsv"
        result_path = temp_dir / "results.tsv"
        manifest_lines = []
        case_number = 0
        actual_rates = set()

        for source_path, group in by_source.items():
            channels, native_rate = read_wav(source_path)
            for case in group:
                start = max(0, math.ceil(case["region_start"] * native_rate))
                end = min(len(channels[0]), math.floor(case["region_end"] * native_rate))
                if end - start < 8:
                    case["status"] = "too-short"
                    case["description"] = "8サンプル未満"
                    continue
                samples = select_channel(channels, start, end, channel_mode)
                if "stable" not in case:
                    stability_samples, stability_rate = decimate(samples, native_rate, 8000)
                    stability = frame_stability(
                        stability_samples, stability_rate, case["reference_hz"],
                        mad_limit, span_limit, min_frames, ref_offset_limit)
                    if stability:
                        case["stable"] = stability["stable"]
                        case["stability_reason"] = stability["reason"]
                        case["stability_frames"] = stability["frames"]
                        case["stability_mad"] = stability.get("mad", 0.0)
                        case["stability_span"] = stability.get("span", 0.0)
                        case["stability_ref_offset"] = stability.get("ref_offset", 0.0)
                    else:
                        case["stable"] = False
                        case["stability_reason"] = "no-frames"
                        case["stability_frames"] = 0
                        case["stability_mad"] = 0.0
                        case["stability_span"] = 0.0
                        case["stability_ref_offset"] = 0.0
                samples, analysis_rate = decimate(samples, native_rate, rate)
                if len(samples) < 32:
                    case["status"] = "too-short"
                    case["description"] = "32サンプル未満"
                    continue
                case_number += 1
                case_id = f"c{case_number:04d}"
                case["case_id"] = case_id
                case["analysis_rate"] = analysis_rate
                actual_rates.add(round(analysis_rate, 3))
                raw_path = temp_dir / f"{case_id}.f32"
                with raw_path.open("wb") as output:
                    array("f", samples).tofile(output)
                manifest_lines.append("\t".join([
                    case_id,
                    str(raw_path),
                    f"{analysis_rate:.6f}",
                    f"{case['expected_hz']:.6f}",
                    f"{case['region_end'] - case['region_start']:.6f}",
                    "1" if (case["region_end"] - case["region_start"]) < 0.08 else "0",
                ]))

        if not manifest_lines:
            return actual_rates
        manifest_path.write_text("\n".join(manifest_lines) + "\n", encoding="utf-8")
        command = [lua, str(helper), str(manifest_path), str(result_path)]
        completed = subprocess.run(command, cwd=repo_root, capture_output=True,
                                   text=True, encoding="utf-8", errors="replace",
                                   timeout=timeout)
        if completed.returncode != 0:
            raise RuntimeError(
                f"Lua benchmark failed ({completed.returncode}):\n{completed.stderr}\n{completed.stdout}")

        results = {}
        for line in result_path.read_text(encoding="utf-8").splitlines()[1:]:
            if not line:
                continue
            fields = line.split("\t", 5)
            while len(fields) < 6:
                fields.append("")
            results[fields[0]] = fields
        for case in cases:
            case_id = case.get("case_id")
            if not case_id or case_id not in results:
                if not case["status"]:
                    case["status"] = "missing"
                    case["description"] = "Luaの結果がありません"
                continue
            _, status, value, estimated, observations, description = results[case_id]
            case["status"] = status
            case["description"] = description
            case["observations"] = int(observations or 0)
            if value:
                case["cents"] = float(value)
            if estimated:
                case["estimated_hz"] = float(estimated)
    return actual_rates


def summarize(cases):
    stable = [case for case in cases if case.get("stable")]
    unstable = [case for case in cases if case.get("stability_reason") == "unstable"]
    mismatch = [case for case in cases if case.get("stability_reason") == "reference-mismatch"]
    short = [case for case in cases if case.get("stability_reason") in
             ("short", "no-frames", "too-short")]

    def percentile(values, fraction):
        if not values:
            return 0.0
        return values[min(len(values) - 1, int(fraction * (len(values) - 1)))]

    def accuracy(group):
        ok = [case for case in group
              if case["status"] == "ok" and case.get("estimated_hz")]
        errors = [cents(case["estimated_hz"], case["reference_hz"]) for case in ok]
        absolute = sorted(abs(value) for value in errors)
        total = len(group)
        return {
            "total": total,
            "ok": len(ok),
            "no_estimate": total - len(ok),
            "conflict": sum(1 for case in group if case["status"] == "conflict"),
            "median_abs": statistics.median(absolute) if absolute else 0.0,
            "mean_abs": statistics.fmean(absolute) if absolute else 0.0,
            "p95_abs": percentile(absolute, 0.95),
            "mean_signed": statistics.fmean(errors) if errors else 0.0,
            "within_10": sum(1 for value in absolute if value <= 10.0) / total if total else 0.0,
            "within_25": sum(1 for value in absolute if value <= 25.0) / total if total else 0.0,
            "within_50": sum(1 for value in absolute if value <= 50.0) / total if total else 0.0,
            "octave": sum(1 for value in errors if abs(value) >= 600.0),
        }

    stable_result = accuracy(stable)
    unstable_result = {
        "total": len(unstable),
        "refused": sum(1 for case in unstable if case["status"] in ("none", "conflict")),
        "corrected": sum(1 for case in unstable
                         if case["status"] == "ok" and case.get("estimated_hz")),
        "other": sum(1 for case in unstable if case["status"] not in ("ok", "none", "conflict")),
    }
    return {
        "total": len(cases),
        "stable": stable_result,
        "unstable": unstable_result,
        "mismatch": len(mismatch),
        "short": len(short),
    }


def write_csv(cases, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as output:
        writer = csv.writer(output)
        writer.writerow([
            "rate", "case", "file", "unit", "name", "phonemes", "start", "end",
            "reference_hz", "reference_midi", "expected_note", "expected_hz",
            "stable", "stability_reason", "stability_frames", "stability_mad",
            "stability_span", "stability_ref_offset",
            "status", "estimated_hz", "error_cents", "observations", "description",
        ])
        for case in cases:
            estimated = case.get("estimated_hz")
            error = None
            if estimated is not None:
                error = cents(estimated, case["reference_hz"])
            writer.writerow([
                case.get("analysis_rate", ""), case.get("case_id", ""),
                case["json"].name, case["unit_id"], case["name"], case["phonemes"],
                f"{case['region_start']:.4f}", f"{case['region_end']:.4f}",
                f"{case['reference_hz']:.3f}", f"{case['reference_midi']:.3f}",
                case["expected_note"], f"{case['expected_hz']:.3f}",
                "yes" if case.get("stable") else "no",
                case.get("stability_reason", ""),
                case.get("stability_frames", 0),
                f"{case.get('stability_mad', 0.0):.1f}",
                f"{case.get('stability_span', 0.0):.1f}",
                f"{case.get('stability_ref_offset', 0.0):+.1f}",
                case.get("status", ""),
                "" if estimated is None else f"{estimated:.3f}",
                "" if error is None else f"{error:.2f}",
                case.get("observations", 0), case.get("description", ""),
            ])


RESULT_KEYS = (
    "status", "cents", "estimated_hz", "observations", "description",
    "case_id", "analysis_rate",
)


def reset_results(cases):
    for case in cases:
        for key in RESULT_KEYS:
            case.pop(key, None)


def self_test(lua: str) -> int:
    """Generate a synthetic stable tone and check the whole benchmark path."""
    with tempfile.TemporaryDirectory(prefix="nama-pitch-selftest-") as temp:
        folder = Path(temp)
        wav_path = folder / "tone.wav"
        with wave.open(str(wav_path), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(48000)
            frames = bytearray()
            for index in range(48000):
                value = int(0.3 * 32767 * math.sin(2 * math.pi * 220.0 * index / 48000))
                frames += struct.pack("<h", value)
            output.writeframes(bytes(frames))
        document = {
            "format": "nama-voices",
            "version": 1,
            "source": {"path": str(wav_path), "sampleRate": 48000, "channels": 1,
                       "bits": 16, "frames": 48000, "seconds": 1.0},
            "units": [{
                "id": "u001", "name": "a", "phonemes": "a",
                "start": 0.1, "end": 0.9, "phoneme_starts": [0.1],
                "pitch": {"midi": 57.0, "hz": 220.0, "strength": 1.0},
            }],
        }
        (folder / "tone.nama-voices.json").write_text(
            json.dumps(document, ensure_ascii=False), encoding="utf-8")

        cases = load_cases(folder, folder, "*.nama-voices.json", "vowel", 0.0,
                           "nearest", 0.0, None)
        if len(cases) != 1:
            print(f"FAIL: self-test cases={len(cases)}", file=sys.stderr)
            return 1
        for rate in (8000, 12000):
            reset_results(cases)
            run_rate(cases, rate, "mono", lua, 60.0, 25.0, 100.0, 8, 100.0)
            summary = summarize(cases)
            stable = summary["stable"]
            if stable["total"] != 1 or stable["ok"] != 1 or not cases[0].get("estimated_hz"):
                print(f"FAIL: self-test at {rate} Hz: {cases[0]}", file=sys.stderr)
                return 1
            error = cents(cases[0]["estimated_hz"], cases[0]["reference_hz"])
            if abs(error) > 10.0:
                print(f"FAIL: self-test at {rate} Hz: error={error:.1f}c", file=sys.stderr)
                return 1
            print(f"PASS: self-test {rate} Hz error={error:+.1f}c")
    print("OK: benchmark self-test")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json-dir", type=Path, default=DEFAULT_JSON_DIR)
    parser.add_argument("--wav-dir", type=Path, default=DEFAULT_WAV_DIR)
    parser.add_argument("--pattern", default="*.nama-voices.json")
    parser.add_argument("--rates", default="8000,12000",
                        help="カンマ区切りの解析レート（既定: 8000,12000）")
    parser.add_argument("--region", choices=("vowel", "unit"), default="vowel")
    parser.add_argument("--pad-ms", type=float, default=0.0,
                        help="vowel領域を後方へ広げる量（ms）")
    parser.add_argument("--channel", choices=("mono", "loudest"), default="mono")
    parser.add_argument("--expected", choices=("nearest", "exact"), default="nearest",
                        help="nearest=ファイル名の音名を想定、exact=FCPEの周波数を直接使用")
    parser.add_argument("--min-strength", type=float, default=0.0)
    parser.add_argument("--max-cases", type=int, default=None)
    parser.add_argument("--skip-hash-check", action="store_true",
                        help="JSONのsource.sha256とWAVの照合を省略する")
    parser.add_argument("--stability-mad", type=float, default=25.0,
                        help="安定判定に使うMAD上限（cent）")
    parser.add_argument("--stability-span", type=float, default=100.0,
                        help="安定判定に使う10-90%%スパン上限（cent）")
    parser.add_argument("--stability-min-frames", type=int, default=8,
                        help="安定判定に必要な40msフレーム数")
    parser.add_argument("--ref-offset", type=float, default=100.0,
                        help="FCPE中央値との差がこれを超えたらreference-mismatch")
    parser.add_argument("--lua", default="lua", help="Lua 5.4の実行ファイル")
    parser.add_argument("--timeout", type=float, default=300.0)
    parser.add_argument("--csv", type=Path, default=Path("pitch-benchmark.csv"))
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--self-test", action="store_true",
                        help="合成音でベンチマーク経路を自己テストする")
    args = parser.parse_args()

    if np is None:
        print("numpy が必要です: python -m pip install numpy", file=sys.stderr)
        return 2
    if args.self_test:
        return self_test(args.lua)
    if not args.json_dir.is_dir():
        print(f"JSONフォルダーがありません: {args.json_dir}", file=sys.stderr)
        return 2
    cases = load_cases(args.json_dir, args.wav_dir, args.pattern, args.region,
                       args.pad_ms, args.expected, args.min_strength, args.max_cases,
                       not args.skip_hash_check)
    if not cases:
        print("比較できる区間がありません。", file=sys.stderr)
        return 2

    rates = [int(value) for value in args.rates.split(",") if value.strip()]
    all_cases = []
    print(f"cases={len(cases)} region={args.region} pad={args.pad_ms:g}ms channel={args.channel}")
    for rate in rates:
        reset_results(cases)
        actual_rates = run_rate(
            cases, rate, args.channel, args.lua, args.timeout,
            args.stability_mad, args.stability_span, args.stability_min_frames,
            args.ref_offset)
        summary = summarize(cases)
        stable = summary["stable"]
        unstable = summary["unstable"]
        actual = ",".join(f"{value:g}" for value in sorted(actual_rates)) or "-"
        print(
            f"{rate:>6} Hz (actual {actual}): "
            f"stable={stable['total']} ok={stable['ok']} "
            f"none={stable['no_estimate']} | "
            f"median|err|={stable['median_abs']:.1f}c "
            f"mean={stable['mean_abs']:.1f}c p95={stable['p95_abs']:.1f}c "
            f"within25={stable['within_25'] * 100:.0f}% "
            f"within50={stable['within_50'] * 100:.0f}% "
            f"octave={stable['octave']} bias={stable['mean_signed']:+.1f}c"
        )
        print(
            f"        unstable={unstable['total']} refused={unstable['refused']} "
            f"corrected={unstable['corrected']} | "
            f"ref-mismatch={summary['mismatch']} short={summary['short']} "
            f"(all {summary['total']})"
        )
        for case in cases:
            copy = dict(case)
            copy["analysis_rate"] = rate
            all_cases.append(copy)
        if args.verbose:
            for case in cases:
                label = f"{case['case_id']} {case['json'].name}/{case['unit_id']} {case['phonemes']}"
                if case.get("stable") and case["status"] == "ok" and case["estimated_hz"]:
                    error = cents(case["estimated_hz"], case["reference_hz"])
                    if abs(error) > 25.0:
                        print(f"  stable {label}: {error:+.1f}c")
                elif case.get("stable") and case["status"] != "ok":
                    print(f"  stable {label}: {case['status']} {case['description']}")
                elif case.get("stability_reason") == "unstable" and case["status"] == "ok":
                    print(f"  unstable {label}: corrected (false positive?)")
                elif case.get("stability_reason") == "reference-mismatch":
                    print(f"  mismatch {label}: ref offset {case.get('stability_ref_offset', 0):+.1f}c")

    write_csv(all_cases, args.csv)
    print(f"CSV: {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
