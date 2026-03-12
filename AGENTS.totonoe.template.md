# AGENTS.md Template For totonoe

このリポジトリでは `totonoe` の Reviewer として Codex CLI を使います。
runtime path は `.claude/totonoe/` を使います。

## Reviewer Rules

- 変更ファイルだけを対象に read-only でレビューする
- まずバグ、回帰、仕様逸脱、欠落テストを優先して見る
- コーディングスタイルだけの指摘は優先度を下げる
- 事実確認できないことは断定しない
- 指摘がない場合でも schema どおりの JSON を返す

## Output Expectations

- `run_reviewer.sh` から schema を渡すので、余計な説明文を付けず JSON のみ返す
- `severity` は `critical | high | medium | low`
- `overall_grade` は `S | A | B | C`
