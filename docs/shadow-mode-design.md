# Reviewer Shadow Mode 設計メモ

## 目的

`totonoe` の現行構成では、Reviewer / Judge の評価プロバイダーは `Codex` を第一候補とし、quota / token / rate-limit / context-length 系の失敗時のみ `Gemini` にフォールバックする。

この設計メモは、将来的に `Codex` と `Gemini` を常時比較できる `shadow mode` を追加する場合の設計方針を整理するためのものである。

現時点での優先順位は次のとおり。

1. 公開時点では現行 `fallback` を維持する
2. 公開後、Reviewer のみ `shadow mode` を追加する
3. `shadow mode` の観測結果を見たあとで `consensus` を検討する

## shadow mode の目的

`shadow mode` は「Gemini も動かせるようにする」ための機能ではない。目的は以下の 3 点に固定する。

1. `Codex` と `Gemini` の指摘の一致率を観測する
2. 将来 `consensus` に移行するかどうかの判断材料を得る
3. `Codex` が見落とした指摘を `Gemini` が拾っているかを確認する

この目的が曖昧なまま実装すると、`shadow` の出力が蓄積されるだけで誰にも参照されない。

## 非目的

初期の `shadow mode` では、以下は行わない。

- `done` 判定への反映
- `judge.json` の recommendation への反映
- `Manager` の最終決定ロジックの変更
- `Codex` と `Gemini` の自動多数決
- `Judge` の dual evaluation

## 導入対象

初期導入の対象は `Reviewer` のみとする。

理由:

- `Reviewer` は findings / grade / critical_count の比較に閉じるため、観測設計がしやすい
- `Judge` まで両系統化すると `done / fix / continue / human` の不一致裁定が必要になる
- `Judge` の recommendation が割れると `totonoe` 全体の完了判定が不安定になる

## 評価モード

将来の拡張を見据えて、評価モードは Reviewer と Judge で分けて持つ。

- `fallback`
  - 現行仕様
  - primary が失敗したときのみ secondary に切り替える
- `shadow`
  - primary を正本として採用する
  - secondary も追加で実行し、比較用の結果を保存する
  - `done` 判定や state 遷移には使わない
- `consensus`
  - 将来用
  - 両者の結果を正式入力として扱う
  - 初期実装対象ではない

## 設定ファイル

評価モードは runtime state ではなく、専用設定ファイルで管理する。

配置先:

`/.claude/totonoe/config.json`

例:

```json
{
  "providers": {
    "primary": "codex",
    "secondary": "gemini"
  },
  "reviewer": {
    "mode": "fallback"
  },
  "judge": {
    "mode": "fallback"
  }
}
```

### この場所に置く理由

- `provider_state.json` は runtime 状態であり、運用設定を混ぜるべきではない
- `.claude/settings.json` は Claude Code の権限設定であり、totonoe 独自設定を混ぜるべきではない
- `.claude/totonoe/` 配下なら totonoe 固有設定として自然に管理できる

## 保存先

`shadow mode` の出力は各 round ディレクトリに保存する。

初期案:

- `reviewer_primary.json`
- `reviewer_shadow.json`
- `reviewer_shadow_summary.json`

`reviewer_primary.json`:

- primary provider の正本出力
- 現在の `reviewer_aggregate.json` 生成に使う元データ

`reviewer_shadow.json`:

- secondary provider の比較用出力
- state 遷移には使わない

`reviewer_shadow_summary.json`:

- 差分観測用の要約
- `critical_count` 差
- `overall_grade` 差
- findings 件数差
- 片方だけが出した high / critical 指摘の一覧

## 初期フロー

Reviewer が `shadow mode` のときの想定フロー:

1. primary provider を実行する
2. 正本の shape check を通す
3. `reviewer_primary.json` に保存する
4. secondary provider を実行する
5. shadow 側の shape check を通す
6. `reviewer_shadow.json` に保存する
7. `reviewer_shadow_summary.json` を生成する
8. runtime state は primary の結果だけで進める

### 重要な原則

- primary が成功し shadow が失敗しても、loop 自体は継続する
- shadow の失敗は `warning` / `event log` として残す
- `shadow mode` は比較観測機能であり、主系を止めない

## events.jsonl の拡張

`shadow mode` では監査ログにも provider の役割を残した方がよい。

例:

```json
{
  "type": "ai_exec",
  "role": "reviewer",
  "provider": "codex",
  "provider_role": "primary",
  "result": "success"
}
```

```json
{
  "type": "ai_exec",
  "role": "reviewer",
  "provider": "gemini",
  "provider_role": "shadow",
  "result": "success"
}
```

## Manager / Human の見方

初期の `shadow mode` では、`Manager` が必ず `shadow` を見る運用にはしない。

見る主体は以下を想定する。

- まずは人間の運用者
- 必要に応じて Manager が spot check 時に参照

特に確認したい観点:

- `Codex` と `Gemini` の `critical_count` が継続的にズレるか
- `Gemini` が一貫して拾うが `Codex` が見落とすカテゴリがあるか
- `overall_grade` の傾向差が大きいか

## consensus への布石

`consensus` はまだ実装しないが、不一致判定の骨格だけは先に定義しておく。

### 不一致の定義案

- `critical_count` の差が 2 以上
- `overall_grade` が 2 段階以上違う
- `Judge` で一方が `done`、もう一方が `fix`

### 不一致時の扱い案

初期方針:

- 自動的に `human` へ送る

将来の選択肢:

- より厳しい方を採用する
- 一定条件下でのみ保守的自動採用を許可する

初期から「厳しい方を自動採用」にすると、loop が過度に保守的になりやすい。まずは `human` 送りが安全。

## 実装フェーズ

### Phase 1

- 現行 `fallback` を維持したまま公開

### Phase 2

- Reviewer にのみ `shadow mode` を追加
- `config.json` を導入
- round ごとの shadow 出力保存を追加

### Phase 3

- 観測結果をレビューする
- `shadow` の結果が運用上価値を持つか判断する
- 必要なら `consensus` を検討する

## 実装前に決めるべきこと

1. `shadow` 結果を誰が見るか
2. `reviewer_shadow_summary.json` に最低限含める差分項目
3. `shadow` 実行失敗時の扱いを warning に留めるか
4. `config.json` の未設定時デフォルトを `fallback` に固定するか

## 現時点での推奨

現段階では、`shadow mode` をいますぐ実装するよりも、公開を優先する方がよい。

次に手を付けるなら:

1. `config.json` の導入
2. Reviewer-only の `shadow mode`
3. shadow 比較結果を round に保存する仕組み

ここまでで十分に観測価値が出る。そのあとで `consensus` を判断すれば遅くない。
