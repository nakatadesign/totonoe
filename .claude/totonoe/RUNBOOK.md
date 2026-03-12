# RUNBOOK

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

provider 状態も一緒に見たい場合:

```bash
.claude/totonoe/bin/status.sh --job-name sample-feature --provider-state
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

必要な環境変数:

```bash
export GEMINI_API_KEY="AIza..."
export GEMINI_MODEL="gemini-2.5-pro"
export AI_PROVIDER_COOLDOWN_BASE_SECONDS="1800"
export CODEX_MODEL="gpt-5-codex"  # audit log only; this does not pass --model to codex exec
```

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

## 6. provider 状態を手動で戻す

```bash
.claude/totonoe/bin/reset_provider.sh --job-name sample-feature
```

`Codex` 側の制限が解消したあと、cooldown を即解除したいときに使う。
このコマンドは `cooldown_until` だけでなく `codex_consecutive_failures` もリセットする。

## 7. よく見るファイル

- `runtime/<job>/state.json`
- `runtime/<job>/provider_state.json`
- `runtime/<job>/events.jsonl`
- `runtime/<job>/rounds/<NNN>/claude_summary.json`
- `runtime/<job>/rounds/<NNN>/reviewer_aggregate.json`
- `runtime/<job>/rounds/<NNN>/judge.json`

`ai_exec` の監査ログだけ見たい場合:

```bash
jq 'select(.type == "ai_exec")' .claude/totonoe/runtime/sample-feature/events.jsonl
```

## 8. 注意点

- `jq >= 1.6` と `codex` が必要
- `Gemini` fallback を使う場合は `curl` と `GEMINI_API_KEY` が必要
- cooldown 中に Gemini が成功しても `codex_consecutive_failures` は維持される。Codex 回復確認までは failure count を保持する設計
- `record_claude_round.sh` へ渡す changed file はリポジトリ内パスにする
- `done` を指定しても条件未達なら自動で `human` に降格する
- `runtime/` は Git 管理しない
- `provider_state.json` も手動編集しない
