## Totonoe 運用

このリポジトリでは、`totonoe` を使って Claude Code が controller になり、shell script 経由で Codex CLI を呼び出して進行を制御する。
runtime path は `.claude/totonoe/` を使う。

4役構成:

- **Manager** (`.claude/agents/MANAGER.md`): totonoe の最終決定・指揮。実装はしない
- **Analyst** (`run_judge.sh` + `SUPERVISOR.md`): reviewer 結果を集約し recommendation を提示する。最終決定はしない
- **Engineer** (`<project>-engineer.md`): 実装専任
- **Reviewer** (`run_reviewer.sh` + `AGENTS.md`): read-only レビュー

### /loop 起動後の基本動作

active job がある場合、各 tick で次を行う。

1. `status.sh --job-name <active-job> --json` で state を読む
2. `status=done` なら完了報告して止まる
3. `status=human` なら判断待ちを報告して止まる
4. `status=init / fix_requested / continue_requested` の場合:
   - 実装または追加確認を行う
   - summary markdown を runtime 配下に保存する
   - `record_claude_round.sh` を実行する
   - `run_reviewer.sh` を実行する
   - `run_judge.sh` を実行する
   - `manager_review` に入ったら Manager に委譲する
5. `status=reviewing` なら `run_reviewer.sh` から再開する
6. `status=judging` なら `run_judge.sh` から再開する
7. `status=manager_review` なら Manager に委譲して最終決定を確定する
