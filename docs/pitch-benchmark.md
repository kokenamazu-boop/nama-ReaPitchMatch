# ピッチ検出ベンチマーク

`tools/pitch_benchmark.py` は、ReaScript内のYIN系ピッチ検出を、`nama-voices.json` に保存されたFCPEの音程と比較する開発者向けツールです。ReaScript本体には含めず、配布物にも依存を増やしません。

## 目的

- 8 kHz / 12 kHz の解析レートで、セント誤差・オクターブ誤り・補正なし率を比べる
- 安定した母音と、グライド・ビブラートの多い区間を分けて評価する
- `choose_estimate()` が「補正しない」べき区間で、誤って補正していないか確認する
- 検出器の変更前後で、同じ素材を使って回帰比較する

## 前提

- Lua 5.4（`lua` または `lua5.4`）
- Python 3.10以上
- `numpy`（安定度の分類にのみ使用）
- FCPEで音程を付けた `*.nama-voices.json` と、その `source.path` が指すWAV

```powershell
python -m pip install numpy
```

## 実行

```powershell
python tools\pitch_benchmark.py ^
  --json-dir "D:\vst開発\jinriki\vowel-boundaries-fcpe" ^
  --rates 8000,12000 ^
  --lua "C:\path\to\lua.exe"
```

`lua` がPATHにある場合、`--lua` は省略できます。

### 主なオプション

| オプション | 既定 | 内容 |
|---|---|---|
| `--json-dir` | `D:\vst開発\jinriki\vowel-boundaries-fcpe` | `*.nama-voices.json` を探す場所 |
| `--wav-dir` | `D:\vst開発\jinriki` | JSONの `source.path` が見つからない場合のWAV探索先 |
| `--rates` | `8000,12000` | 比較する解析レート（カンマ区切り） |
| `--region` | `vowel` | `vowel`＝最後の音素開始から終端、`unit`＝候補全体 |
| `--pad-ms` | `0` | 母音区間の開始を後方へ広げる量。窓拡張の実験用 |
| `--channel` | `mono` | `mono`＝全ch平均、`loudest`＝最もエネルギーの大きいch |
| `--expected` | `nearest` | `nearest`＝FCPE音程に最も近い半音をファイル名の音名とみなす、`exact`＝FCPE周波数を直接使う |
| `--stability-mad` | `25` | 安定判定のMAD上限（cent） |
| `--stability-span` | `100` | 安定判定の10〜90%スパン上限（cent） |
| `--stability-min-frames` | `8` | 安定判定に必要な40msフレーム数 |
| `--ref-offset` | `100` | FCPE中央値との差がこれを超えたら `reference-mismatch` |
| `--csv` | `pitch-benchmark.csv` | 全ケースのCSV出力先 |
| `--skip-hash-check` | off | JSONの `source.sha256` とWAVの照合を省略 |
| `--verbose` | off | 25セント超の誤差、未検出、グライド区間の誤補正を表示 |
| `--self-test` | off | 合成220 Hz音でベンチマーク経路を自己テスト |

`--self-test` は外部データ不要です。

```powershell
python tools\pitch_benchmark.py --self-test --lua "C:\path\to\lua.exe"
```

## 判定方法

1. JSONの `units` から、FCPEの `pitch.hz` がある区間だけを使います。JSONに `source.sha256` がある場合はWAVと照合し、不一致ならスキップします（`--skip-hash-check` で省略可）。
2. 母音区間は、`phoneme_starts` の最後（末尾の音素が母音のとき）から `unit.end` までとします。無い場合は `start + 0.35 * 長さ` にフォールバックします。
3. 区間をReaScriptと同じように間引き、`tools/bench_pitch.lua` で `frame_pitch()` と `choose_estimate()` を実行します。
4. 別の自己相関（40ms窓・10msホップ）で区間の安定度を分類します。

### 安定度の分類

| 分類 | 条件 | 評価 |
|---|---|---|
| `stable` | MAD ≤ 25c、10〜90%スパン ≤ 100c、8フレーム以上、FCPE中央値との差 ≤ 100c | セント誤差を評価 |
| `unstable` | 上記の安定条件を満たさない | 補正しないのが正しい。`corrected` は誤補正の候補 |
| `reference-mismatch` | FCPE中央値とフレーム中央値の差が100c超 | グライドで中央値が代表値になっていない。精度評価から除外 |
| `short` | 8フレーム未満、または解析サンプル不足 | 評価不能。窓拡張の検討対象 |

`stable` の判定に使う自己相関は**ベンチマーク用の分類器**であり、評価対象のYINではありません。FCPEのフレーム単位カーブがJSONに無いため、区間の安定度はこの簡易分類で代用しています。

## 2026-10-31 の実測例

`D:\vst開発\jinriki\vowel-boundaries-fcpe` の7フレーズ・58区間、`--region vowel`、`mono`、`nearest` での結果です。

| 解析レート | stable | ok | none | median \|誤差\| | p95 | within 25c | octave | unstable の refused / corrected |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 8 kHz | 12 | 9 | 3 | 4.2c | 8.3c | 75% | 0 | 17 / 13 |
| 12 kHz | 12 | 8 | 4 | 2.6c | 10.7c | 67% | 0 | 18 / 12 |

内訳：`reference-mismatch=3`、`short=13`。

### 読み方

- **安定区間ではYINは十分に正確**。中央値4.2c（8k）／2.6c（12k）で、オクターブ誤りは0件でした。
- **8kと12kの差は小さい**。8kは検出数が1件多く、12kは中央値誤差が小さい。今回のデータだけでは既定値を変える根拠になりません。
- **グライド区間の誤補正が13/30件**。`choose_estimate()` は区間内の安定した一部を拾って補正できます。1音節＝1アイテムなら問題ありませんが、フレーズ全体を1アイテムにした場合は誤補正の危険があります。
- **短い区間が13/58件**。`short` は評価不能で、60ms程度の後方窓拡張（`--pad-ms`）や、母音区間を明示するサイドカーJSONの価値があります。
- `reference-mismatch` は、FCPEの中央値がグライドの途中を指しているケースです。FCPEが悪いのではなく、中央値1つで区間を代表させることの限界です。

### 追加実験

同じデータで、いくつかの条件も試しました。

| 条件 | stable | ok | median \|誤差\| (8k / 12k) | short | unstable corrected |
|---|---:|---:|---:|---:|---:|
| 既定（vowel, mono） | 12 | 9 / 8 | 4.2c / 2.6c | 13 | 13 / 12 |
| `--region unit` | 11 | 8 / 8 | 5.3c / 2.6c | 5 | 14 / 14 |
| `--pad-ms 60` | 10 | 8 / 8 | 5.5c / 2.6c | 5 | 15 / 15 |
| `--channel loudest` | 12 | 8 / 8 | 5.5c / 2.4c | 13 | 13 / 12 |

- **`--pad-ms 60` は短い区間を13→5件に減らす**一方、stableが12→10件に減り、グライドの誤補正が13→15件に増えました。短いアイテムだけに限定し、信頼度で強くゲートする必要があります。
- **`--channel loudest` はこの中央定位の素材ではmono平均よりわずかに不利**（8kのokが9→8）。ただし定位が偏った素材では逆転し得るため、即座に切り替える根拠にはなりません。
- **`--region unit` は母音区間より`reference-mismatch`が増える**（3→9）。子音やグライドを含むため、既定の`vowel`の方が比較しやすいです。

## v1.8.0への反映

このベンチマークの結果を踏まえ、ReaScript本体には次を入れました。

- **時間選択がある場合は、その範囲だけを解析**。フレーズ素材で母音部分を指定でき、グライド区間の誤補正を避けやすくなります。
- 解析レポートに**検出フレーム数と確信度**を表示。数値が低い補正をユーザーが判断できます。
- 8 kHz / 12 kHzの既定値は変更していません。今回のデータでは明確な差がなかったためです。
- 短い区間の窓拡張は既定では行いません。`--pad-ms 60` の実験で誤補正が増えたため、短い素材だけに限定するなどの追加検証が必要です。

## 制約

- FCPEの**フレーム単位カーブ**は、この資料のJSONには保存されていません。そのため「FCPEとのフレーム単位比較」ではなく「FCPE中央値との区間比較」です。
- 安定度の分類は簡易自己相関で、FCPEではありません。分類の境界（25c / 100c / 8フレーム）を変えると件数が変わります。
- 7フレーズ・58区間は小さなデータセットです。既定値の変更は、別の素材でも再現してから行ってください。
- 聴感の評価ではありません。数値が良くても、実際のSoloistの音質・フォルマントは別に確認が必要です。

## ライセンスとデータの扱い

- ベンチマーク本体は `nama-ReaPitchMatch` のMITライセンスです。
- `D:\vst開発` のAGPLコードはインポートせず、FCPEで生成済みの**JSONデータを読むだけ**です。FCPEモデルや素材は再配布しません。
- 出力CSVには素材名・区間・推定値が入ります。`pitch-benchmark*.csv` は `.gitignore` 済みです。共有する場合は内容を確認してください。
