# splitvox

オンライン会議を **システム音声とマイクの2ファイルに分けて録音**し、両方を端末内で
文字起こしして、**話者ラベル付きの Markdown** を出力する macOS メニューバーアプリ。

音声は一切外部に送信されません。会議にボットが参加することもありません。

```markdown
- **[相手]** `00:00:04` 今日はよろしくお願いします
- **[自分]** `00:00:07` よろしくお願いします
```

## なぜ2ファイルに分けるのか

既存の議事録ツールで日本語の話者識別が弱いのは、音声認識の精度が理由ではありません。
**録音の段階で音声が混ざっているから**です。

macOS のシステム音声タップは「スピーカーから出る音すべて」を1本のストリームで返します。
アプリ内蔵の録音を使うツールは、そこにマイクを足した1本の音声を認識器に渡すため、
誰が話したかを声質から推測するしかなくなります。

splitvox は録音の時点で経路を分けます。相手の声はプロセスタップから、自分の声はマイクから、
別々のファイルに書き込みます。**どちらのファイルから来たかで話者が決まる**ので、推測が不要です。

実測（YouTube を再生しながらマイクで発話した20秒の録音）:

```
[相手] ドイツベルギーフランスに囲まれ、面積がですね、神奈川県と同じぐらいの…
[自分] あ、あ、マイクテスト、マイクテスト、…マイクテストをしています。
```

両者が同時に鳴っている状態でも、混入はありませんでした。

## 機能

- **2トラック同時録音** — 会議アプリの出力とマイクを別ファイルへ。両者は1つの集約デバイスに
  載るため単一クロックで駆動され、長時間の会議でも時刻がずれません
- **アプリ単位のキャプチャ** — 通知音や音楽が混入しません。会議アプリだけを指定できます
- **端末内文字起こし** — Apple の SpeechAnalyzer / SpeechTranscriber を使用。日本語対応
- **話者ラベル付き Markdown** — 時系列でマージし、`[自分]` / `[相手]` を付与
- **断片の自動結合** — 認識器が単語の途中で区切った断片を、話者ごとに連結します
- **完全オフライン** — ネットワーク通信を一切行いません

要約機能はありません。出力された Markdown を任意の AI に貼って使う想定です。

## 動作環境

- **macOS 26 (Tahoe) 以降** — `CATapDescription.bundleIDs` と SpeechAnalyzer が macOS 26 以降のため
- Apple Silicon Mac
- Swift 6.2 以降のツールチェーン（ビルド時）

## ビルド & 起動

```bash
git clone <this repo>
cd splitvox
bash scripts/make-app.sh
open Splitvox.app
```

`make-app.sh` は release ビルドの後、`.app` バンドルを生成して署名します。

### 署名について

生バイナリではなく `.app` バンドルを作るのは、**macOS の権限（TCC）がバンドルIDと
コード署名に紐づく**ためです。アドホック署名だとリビルドのたびにマイク権限がリセットされます。

安定した自己署名証明書があればそれを使います。無い場合は以下で1度だけ作成してください。

1. キーチェーンアクセス → 証明書アシスタント → 証明書を作成
2. 名前: `splitvox Self-Signed`
3. 固有名タイプ: **自己署名ルート**
4. 証明書のタイプ: **コード署名**

別名の証明書を使う場合は環境変数で指定できます。

```bash
SPLITVOX_SIGN_IDENTITY="任意の証明書名" bash scripts/make-app.sh
```

## 初回セットアップ

1. **権限** — 初回の録音時に「マイク」と「システム音声録音」の許可を求められます。両方許可してください
2. **会議アプリの指定** — メニューバー → 設定… でバンドルIDを確認します。既定は Chrome です

   ```
   com.google.Chrome
   com.google.Chrome.helper
   ```

   **Chrome は音声を別プロセスから再生する**ため、本体とヘルパーの両方が必要です。
   Zoom を使う場合は `us.zoom.xos` などを追加してください
3. **マイク** — 設定… の入力デバイスから選択します。既定はシステムの既定デバイスです

## 使い方

1. 会議を開始する
2. メニューバーの `●` をクリック → **録音を開始**（アイコンが `⏺` に変わります）
3. 会議が終わったら **録音を停止**（`⋯` の間は文字起こし中です）
4. 完了すると Finder が開き、`transcript.md` が選択されます

出力先:

```
~/Library/Application Support/Splitvox/Recordings/<yyyyMMdd-HHmmss>/
├── me.wav          あなたの声
├── them.wav        会議相手の声
└── transcript.md   話者ラベル付きの書き起こし
```

## 診断コマンド

意図した音声が録れない場合に、どの段階で失敗しているかを切り分けられます。

```bash
# 音を出しているアプリのバンドルIDを実測する（音を鳴らしながら実行）
swift Tools/audio-process-watch.swift 60

# タップの作成可否・ネゴシエートされた形式・リークの有無
./Splitvox.app/Contents/MacOS/Splitvox --probe-tap

# 集約デバイスのチャンネル構成
./Splitvox.app/Contents/MacOS/Splitvox --probe-aggregate

# 実際に録音して、ファイルごとの秒単位の音量を出す
./Splitvox.app/Contents/MacOS/Splitvox --probe-record 20

# 録音から文字起こしまで通す
./Splitvox.app/Contents/MacOS/Splitvox --probe-full 20
```

`them.wav` が無音になる場合は、`audio-process-watch` で「音を出しているのに設定に含まれていない」
バンドルIDを探して設定に追加してください。

## データとプライバシー

| データ | 保存先 | 送信先 | 削除 |
|---|---|---|---|
| 会議の音声 (`me.wav` / `them.wav`) | `~/Library/Application Support/Splitvox/Recordings/` | **なし** | 自動削除しません |
| 書き起こし (`transcript.md`) | 同上 | **なし** | 自動削除しません |
| 設定（バンドルID・入力デバイス） | `UserDefaults` | **なし** | — |

- ネットワーク通信を行いません。文字起こしは Apple のオンデバイスモデルで完結します
- 録音ディレクトリは `0o700`（所有者のみ読み書き可）で作成されますが、**音声とテキストは
  暗号化されていません**。ディスク全体の暗号化（FileVault）の利用を推奨します
- **録音ファイルは自動削除されません。** 会議の音声が蓄積するため、不要になったら
  上記ディレクトリを手動で削除してください
- 録音の対象は設定したバンドルIDのアプリの出力音声と、選択したマイクの入力のみです
- 相手への録音の通知は行いません。**録音の可否や告知は利用者の責任で判断してください**

## 制限事項

- **相手側の話者分離は行いません。** 会議相手が複数いても全員が `[相手]` になります。
  「自分 vs 相手」の2分割までです
- **要約しません。** `transcript.md` を任意の AI に渡してください
- **リアルタイム表示はありません。** 録音を停止してから文字起こしします
- 固有名詞や英単語の認識精度は完璧ではありません（`GDP` → `GDB` など）
- Zoom / Teams は設定でバンドルIDを追加すれば動作する想定ですが、検証していません

## 設計メモ

| レイヤー | ファイル | 役割 |
|---|---|---|
| 起動・常駐 | `main.swift` / `AppDelegate.swift` | メニューバー、録音の駆動 |
| 音声取得 | `Core/ProcessTap.swift` | 会議アプリ出力のタップ |
| | `Core/AggregateDevice.swift` | タップとマイクを単一クロックに載せる |
| | `Core/AggregateRecorder.swift` | 2ファイルへの書き分け |
| | `Core/AudioProcessLookup.swift` / `AudioDeviceLookup.swift` | プロセス・デバイスの解決 |
| 文字起こし | `Core/Transcriber.swift` | SpeechAnalyzer のラッパー |
| 整形 | `Core/TranscriptMerger.swift` | 結合・マージ・Markdown 生成 |
| | `Core/CaptureChannelLayout.swift` | チャンネル配置の解決 |
| 状態 | `Core/RecordingSession.swift` | 録音ライフサイクル |
| 永続化 | `Storage/RecordingStore.swift` / `PreferenceStore.swift` | 保存先・設定 |
| 診断 | `Diagnostics/` / `Tools/` | 実機での切り分け |

テストは OS に依存しない純粋な型（`TranscriptMerger` / `RecordingSession` /
`CaptureChannelLayout` / 各 Store）に集中させています。音声取得と文字起こしは
`Diagnostics/` のコマンドで実機確認します。

```bash
swift test
```

## ライセンス

[MIT](LICENSE)
