# totonoe ランタイムコア

`totonoe` の実行コアです。Claude Code と Codex CLI を組み合わせて、Manager / Engineer / Reviewer / Analyst の 4 役で進める totonoe の基本構成です。
runtime path は `.claude/totonoe/` です。

## 主要ファイル

- `bin/init_job.sh`: job 初期化
- `bin/status.sh`: state 確認
- `bin/record_claude_round.sh`: Engineer の summary と quality gate を記録
- `bin/run_ai_exec.sh`: Codex / Gemini 実行ラッパー
- `bin/run_reviewer.sh`: Codex Reviewer を 3 ファイル単位で実行
- `bin/run_judge.sh`: Codex Analyst を実行
- `bin/reset_provider.sh`: provider 状態を手動で Codex 優先に戻す
- `bin/apply_manager_decision.sh`: Manager の spot check と最終決定
- `SUPERVISOR.md`: Analyst 向けルール
- `schemas/*.json`: Reviewer / Judge の出力 schema

## 状態遷移

`init -> reviewing -> judging -> manager_review -> fix_requested | continue_requested | done | human`

## 方針

- runtime 更新は `bin/*.sh` 経由のみ
- `state.json` の手動編集は禁止
- Reviewer は read-only で実行する
- provider は常に `Codex` 優先で、quota/token 系だけ `Gemini` にフォールバックする
- `done` は 4 条件を満たしたときだけ許可する
- Engineer は `Generic / Security / Test / Perf / Refactor` に専門化できる
- `judge.json` の `engineer_type` は推奨値で、最終的な dispatch は Manager が判断する
