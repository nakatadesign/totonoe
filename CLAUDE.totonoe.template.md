## totonoe 運用

このリポジトリでは `totonoe` を使って開発ループを回します。Claude Code がコントローラーとなり、シェルスクリプト経由で Codex CLI を呼び出して進行を制御します。ランタイムパスは `.claude/totonoe/` です。

### 実行モードの前提

`totonoe` の長時間ループ運用は、隔離された開発環境で `claude --dangerously-skip-permissions` を使う前提で考えてよい。
`claude --permission-mode acceptEdits` のような控えめなモードでも、`totonoe` のような定型スクリプト連続実行では確認が残りやすく、長いループでは止まりやすい。

ただし、これは安全な隔離環境でのみ推奨する。
本番 credential・個人ファイル・広い権限を持つ環境では、無確認実行を前提にしないこと。

### 4つの役割

- **Manager**（`.claude/agents/MANAGER.md`）: ループの最終決定・指揮を担う。実装は行わない
- **Analyst**（`run_judge.sh` + `SUPERVISOR.md`）: Reviewer の結果を集約し、推奨アクションを提示する。最終決定はしない
- **Engineer**（`.claude/agents/GENERIC-ENGINEER.md` を基点に、専門エンジニアへ振り分け）: 実装専任
- **Reviewer**（`run_reviewer.sh` + `AGENTS.md`）: 読み取り専用でレビューを行う

### `/loop` 起動後の動作

有効なジョブがある場合、各ステップで以下を行います。

1. `status.sh --job-name <active-job> --json` で現在の状態を確認する
2. `status=done` なら完了を報告して終了する
3. `status=human` なら判断待ちを報告して停止する
4. `status=init / fix_requested / continue_requested` の場合：
   - 実装または追加確認を行う
   - サマリーの Markdown を runtime 配下に保存する
   - `record_claude_round.sh` を実行する
   - `run_reviewer.sh` を実行する
   - `run_judge.sh` を実行する
   - `manager_review` に遷移したら Manager に委譲する
5. `status=reviewing` なら `run_reviewer.sh` から再開する
6. `status=judging` なら `run_judge.sh` から再開する
7. `status=manager_review` なら Manager に委譲し、最終決定を確定する
