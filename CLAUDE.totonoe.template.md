## totonoe 運用

このリポジトリでは `totonoe` を使って開発ループを回します。Claude Code がコントローラーとなり、シェルスクリプト経由で Codex CLI を呼び出して進行を制御します。ランタイムパスは `.claude/totonoe/` です。

### 実行モードの前提

`totonoe` の長時間ループ運用は、隔離された開発環境で `claude --dangerously-skip-permissions` を使う前提で考えてよい。
`claude --permission-mode acceptEdits` のような控えめなモードでも、`totonoe` のような定型スクリプト連続実行では確認が残りやすく、長いループでは止まりやすい。

ただし、これは安全な隔離環境でのみ推奨する。
本番 credential・個人ファイル・広い権限を持つ環境では、無確認実行を前提にしないこと。

### 起動トリガー

ユーザー入力または貼り付けメッセージが `totonoe start` で始まる場合、そのメッセージ全体を現在の job の loop 開始または再開指示として扱う。
その後に続く `ジョブ名:`, `目的:`, `対象:`, `必須対応:`, `制約:`, `完了条件:`, `現在状態:`, `次の手順:` を優先して読み、現在の状態に応じて次の tick を実行する。

ユーザー入力が `totonoe stop` で始まる場合、現在扱っている job を一時停止したい意図として扱う。
job 名が分かっている場合は `.claude/totonoe/bin/pause_job.sh --job-name <current-job> --reason "<user reason or user requested stop>"` を実行し、それ以上のループ処理を進めずに停止理由と再開方法を報告する。
現在 job が特定できない場合は、推測で止めず、停止対象の job 名を短く確認する。

### 4つの役割

- **Manager**（`.claude/agents/MANAGER.md`）: ループの最終決定・指揮を担う。実装は行わない
- **Analyst**（`run_judge.sh` + `SUPERVISOR.md`）: Reviewer の結果を集約し、推奨アクションを提示する。最終決定はしない
- **Engineer**（`.claude/agents/GENERIC-ENGINEER.md` を基点に、専門エンジニアへ振り分け）: 実装専任
- **Reviewer**（`run_reviewer.sh` + `AGENTS.md`）: 読み取り専用でレビューを行う

### `totonoe start` 受信後の動作

有効なジョブがある場合、各ステップで以下を行います。

1. `status.sh --job-name <active-job> --json` で現在の状態を確認する
2. `status=done` なら完了を報告して終了する
3. `status=human` なら判断待ちを報告して停止する
4. `status=paused` なら停止理由を報告して停止する
   - 再開が必要なら `.claude/totonoe/bin/resume_job.sh --job-name <active-job>` を案内する
   - resume 後に `render_loop_prompt.sh --job-name <active-job>` を再度実行した内容で続行する
5. `status=init / fix_requested / continue_requested` の場合：
   - 実装または追加確認を行う
   - サマリーの Markdown を runtime 配下に保存する
   - `record_claude_round.sh` を実行する
   - `run_reviewer.sh` を実行する
   - `run_judge.sh` を実行する
   - `manager_review` に遷移したら Manager に委譲する
6. `status=reviewing` なら `run_reviewer.sh` から再開する
7. `status=judging` なら `run_judge.sh` から再開する
8. `status=manager_review` なら Manager に委譲し、最終決定を確定する
