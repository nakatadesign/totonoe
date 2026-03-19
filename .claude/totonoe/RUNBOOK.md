# RUNBOOK

> この RUNBOOK は totonoe v2 系ランタイムを前提としています。

## 前提条件

この RUNBOOK は `setup.sh` が実行済みの環境を前提とします。未実行の場合、`bin/` 以下のスクリプトが存在せず Step 1 でエラーになります。

```bash
./setup.sh --target /path/to/your/repo
```

## 1. job を作る

```bash
.claude/totonoe/bin/init_job.sh \
  --job-name sample-feature \
  --goal-template feature_loop
```

## 2. ループ用のプロンプトを出す

```bash
.claude/totonoe/bin/render_loop_prompt.sh --job-name sample-feature
```

出力は `totonoe start` で始まり、`ジョブ名:`, `目的:`, `対象:`, `必須対応:`, `制約:`, `完了条件:`, `現在状態:`, `次の手順:` が続く。これをそのまま Claude Code に貼り付けると、現在の job の loop を開始または再開できる。

provider 状態も一緒に見たい場合:

```bash
.claude/totonoe/bin/status.sh --job-name sample-feature --provider-state
```

急いで止めたい場合は、Claude Code 側で `totonoe stop` と伝えるか、手元で次を実行する。

```bash
.claude/totonoe/bin/pause_job.sh --job-name sample-feature --reason "user requested stop"
```

再開するときは、先に paused 状態を戻してから、改めて loop 用プロンプトを生成する。

```bash
.claude/totonoe/bin/resume_job.sh --job-name sample-feature
.claude/totonoe/bin/render_loop_prompt.sh --job-name sample-feature
```

## 3. Engineer がラウンドを記録する

```bash
.claude/totonoe/bin/record_claude_round.sh \
  --job-name sample-feature \
  --summary-file .claude/totonoe/runtime/sample-feature/summary.md \
  --changed-file lib/example.dart \
  --quality-analyze passed \
  --quality-test passed
```

## 4. Reviewer と Judge を回す

```bash
.claude/totonoe/bin/run_reviewer.sh --job-name sample-feature
.claude/totonoe/bin/run_judge.sh --job-name sample-feature
```

Codex が quota / token / context length / rate limit 系で失敗した場合だけ、内部で `Gemini` へ自動フォールバックする。

必要な環境変数（`.env.example` を `.env` にコピーして設定）:

```bash
cp .env.example .env
# .env を編集して GEMINI_API_KEY を入力
```

`.env` は `common.sh` が自動で読み込むため、手動で `source .env` を実行する必要はない。

`.env` に含まれる主な項目:

| 変数名 | 用途 | 備考 |
|---|---|---|
| `GEMINI_API_KEY` | Gemini API 認証 | 必須。空のままだと fallback / shadow でエラー |
| `GEMINI_MODEL` | Gemini モデル名 | 省略時 `gemini-2.5-flash-lite` |
| `CODEX_MODEL` | 監査ログ記録用 | `codex exec --model` には渡さない |
| `AI_PROVIDER_COOLDOWN_BASE_SECONDS` | Codex 失敗後の冷却時間（秒） | 連続失敗で倍増、最大 7200 秒 |

> **注意**: API キーは `.env` に書き、`.claude/totonoe/config.json` には入れないこと。`config.json` にはモード設定など公開可能な情報のみを置く。
> `gemini-2.5-pro` は project / tier によって free tier で使えない場合があるため、既定モデルは fallback / shadow 用の軽量な `gemini-2.5-flash-lite` としている。

## 5. Manager が確認して決定する

```bash
.claude/totonoe/bin/apply_manager_decision.sh \
  --job-name sample-feature \
  --record-spot-check

.claude/totonoe/bin/apply_manager_decision.sh \
  --job-name sample-feature \
  --decision done
```

### Engineer の専門化と dispatch

`judge.json` に `engineer_type` が含まれる場合、Manager は対応する専門 Engineer を起動する。

| engineer_type | 起動する Engineer |
|---|---|
| `security` | `Security-Engineer` |
| `test` | `Test-Engineer` |
| `performance` | `Perf-Engineer` |
| `refactor` | `Refactor-Engineer` |
| `generic` / 未設定 | `Generic-Engineer` |

運用のポイント:

- `engineer_type` は Analyst による推奨。Manager は内容を見て別の Engineer を選んでよい
- 分類に迷う場合や複数カテゴリにまたがる場合は `Generic-Engineer` を使う
- 専門 Engineer が修正途中で専門外への広がりを感じたら、Manager に再委任を提案する
- 標準語彙は `security / test / performance / refactor / generic`

プロジェクト固有の専門 Engineer を増やす場合:

1. `.claude/agents/<role>-engineer.md` を作成する
2. `SUPERVISOR.md` にキーワードと `engineer_type` の対応を追加する
3. `MANAGER.md` の dispatch テーブルに行を追加する
4. この RUNBOOK の表も更新する

## 6. ナレッジDB（オプション）

### 有効化

ジョブ初期化時に `--with-knowledge` を指定すると、knowledge.db が作成され、Reviewer / Judge の結果が自動的に蓄積されます。

```bash
.claude/totonoe/bin/init_job.sh \
  --job-name sample-feature \
  --goal-template feature_loop \
  --with-knowledge
```

### 過去の知見を確認する

```bash
# 全体サマリー
.claude/totonoe/bin/query_knowledge.sh --type summary

# 未解決の過去指摘（severity 別）
.claude/totonoe/bin/query_knowledge.sh --type findings --severity critical --limit 10

# 過去の Judge 判定傾向
.claude/totonoe/bin/query_knowledge.sh --type verdicts --engineer-type security --limit 5
```

### 教訓の記録

ジョブを `done` で完了するときに `--lesson` を指定すると、教訓が knowledge.db に保存されます。同時にそのジョブの review_findings が「解消済み」に更新されます。

```bash
.claude/totonoe/bin/apply_manager_decision.sh \
  --job-name sample-feature \
  --decision done \
  --lesson "API 境界では必ず入力バリデーションを行うこと"
```

`--lesson` を省略しても done は成立します（review_findings の resolved 更新のみ実行されます）。

過去の教訓を確認するには:

```bash
.claude/totonoe/bin/query_knowledge.sh --type lessons --limit 5
```

### Reviewer への自動注入

knowledge が有効なジョブでは、`run_reviewer.sh` が過去の未解決指摘（`resolved = 0`）を Reviewer の各バッチプロンプトに自動注入します（最大 800 文字、直近 3 件）。注入テキストには「今回のスナップショットのみに基づいて独立にレビューする」旨のバイアス防止指示が含まれます。`lessons` は Reviewer には注入されません。

### Judge への自動注入

knowledge が有効なジョブでは、`run_judge.sh` が過去の判定傾向を Judge プロンプトに自動注入します（最大 500 文字、直近 3 件）。注入テキストにはバイアス防止指示が含まれ、Judge は今回の指摘内容に基づいて独立に判断します。

### 無効化

`--with-knowledge` を指定しなければ、knowledge.db は作成されません。既存の knowledge.db を無効にしたい場合は、ファイルを削除またはリネームしてください。ループの動作には影響しません。

## 7. provider 状態を手動で戻す

```bash
.claude/totonoe/bin/reset_provider.sh --job-name sample-feature
```

`Codex` 側の制限が解消したあと、cooldown を即解除したいときに使う。
このコマンドは `cooldown_until` だけでなく `codex_consecutive_failures` もリセットする。

## 8. よく見るファイル

- `runtime/<job>/state.json`
- `runtime/<job>/provider_state.json`
- `runtime/<job>/events.jsonl`
- `runtime/<job>/rounds/<NNN>/claude_summary.json`
- `runtime/<job>/rounds/<NNN>/reviewer_aggregate.json`
- `runtime/<job>/rounds/<NNN>/reviewer_shadow_status.json`（shadow mode 時のみ）
- `runtime/<job>/rounds/<NNN>/judge.json`

`ai_exec` の監査ログだけ見たい場合:

```bash
jq 'select(.type == "ai_exec")' .claude/totonoe/runtime/sample-feature/events.jsonl
```

## 9. 注意点

- `jq >= 1.6` と `codex` が必要
- `Gemini`（fallback / shadow）を使うには `curl` と `GEMINI_API_KEY` が必要（`.env` で設定）
- cooldown 中に Gemini が成功しても `codex_consecutive_failures` は維持される。Codex 回復確認までは failure count を保持する設計
- `record_claude_round.sh` へ渡す changed file はリポジトリ内パスにする
- `done` を指定しても条件未達なら自動で `human` に降格する
- `runtime/` は Git 管理しない
- `provider_state.json` も手動編集しない
- `flock` が使えない環境では `mkdir` ベースの lock fallback を使う。異常終了で `.job.lock.d` が残った場合は owner PID の生存確認を行い、stale lock を自動回収する
- shadow mode では primary が Gemini fallback を使った batch の shadow を自動スキップする。`reviewer_shadow_status.json` で各 batch の状態（`success` / `skipped` / `failed`）を確認できる
- shadow の失敗や欠損で primary の loop が止まることはない
