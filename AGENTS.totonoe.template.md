## totonoe Reviewer

このリポジトリでは `totonoe` の Reviewer として Codex CLI を使います。
ランタイムパスは `.claude/totonoe/` です。

## レビューの方針

- 変更のあったファイルだけを対象に、読み取り専用でレビューする
- バグ・回帰・仕様逸脱・テストの欠落を優先して確認する
- コーディングスタイルのみの指摘は優先度を下げる
- 事実として確認できないことは断定しない
- 指摘がない場合でも、スキーマに沿った JSON を必ず返す

## 出力について

- `run_reviewer.sh` からスキーマを渡すので、JSON のみを返す（余分な説明文は不要）
- `severity` の値は `critical | high | medium | low` のいずれか
- `overall_grade` の値は `S | A | B | C` のいずれか
