# totonoe

**AIエージェントが実装・評価を分担する開発ループ設計**

現在の公開安定版は **v2.0.0** です。`main` ブランチでは v3 系の開発を進めており、runtime core を `.claude/totonoe/` から `.totonoe/` へ移動して Claude Code の permission UX との衝突を解消しています。
v2.0.0 の詳細は [GitHub Releases の v2.0.0](https://github.com/nakatadesign/totonoe/releases/tag/v2.0.0) を参照してください。

開発作業を整える `totonoe` は、Claude Code（実装）と Codex CLI（評価）の役割を分離した Bash ベースの開発ループテンプレートです。
Gemini はオプション対応——Codex 枯渇時の自動引き継ぎ（fallback）と、評価を並走比較する shadow mode として利用できます。

同じ AI に自分の出力を採点させない——「セルフ採点問題」を構造で解決します。品質基準を満たすまでループは続き、完了の判断は厳格な条件だけが下します。

---

## どんな人に向いているか

- Claude Code を使ってアプリやシステムを開発しながら、別の AI に評価させるループを回したい人
- Claude と ChatGPT のサブスクを活用して、API 従量課金に依存しない開発ループを組みたい人

---

## このテンプレートでできること

**Manager → Engineer → Reviewer → Analyst → Manager** のループを bash スクリプトだけで回します。Analyst は `run_judge.sh` が `SUPERVISOR.md` の指示に従って実行します。

- **実装** は Claude Code（Engineer）が担当する
- **評価** は Codex（Reviewer / Analyst）が独立して行う
- **完了判定** は Manager が厳格な4条件で判断する。Engineer の自己申告では完了にならない
- **Gemini を設定している場合**、Codex のトークン上限到達時に自動でフォールバックできる（optional）

> 例: Reviewer は毎回 `S / A / B / C` のいずれかを返しますが、それだけでは `done` にはなりません。`done` は「critical_count が 0」「quality gate が通っている」「Judge が `done` を推奨している」「Manager の spot check がある」という条件が揃ったときだけ確定します。

Python や追加フレームワークへの依存はありません。`setup.sh` を一度実行するだけで、既存のリポジトリにそのまま導入できます。

---

## このテンプレートでできないこと

- ホスティングや外部サービスとしての提供ではありません
- 「人間のレビューが不要になる」ことを保証するものでもありません
- 汎用のエージェントフレームワークを目指したものでもありません

あくまで「開発サイクルの品質を上げるための構造」を提供するテンプレートです。

---

## 必要なもの

| ツール      | 役割                                 | プラン            |
| ----------- | ------------------------------------ | ----------------- |
| Claude Code | 実装・修正（Engineer）               | Claude Max 推奨   |
| Codex CLI   | レビュー・判定（Reviewer / Analyst） | ChatGPT Plus 以上 |
| Gemini API  | fallback / shadow 用（optional）     | API キーのみ      |

`GEMINI_API_KEY` がなくても Codex-only の通常運用は成立します。Gemini を設定すると、Codex がトークン上限やレート制限で使えないときに自動で引き継ぐ fallback として機能します。shadow mode では Codex と Gemini の評価を並走比較できます。

その他、`bash` / `jq 1.6以上` / `perl` または `realpath` が必要です。Gemini の fallback / shadow を使う場合は `curl` も必要です。

Claude Code の UI/UX をそのまま使いながら、バックグラウンドで Codex が評価を担う構成のため、普段の Claude Code の使い方を大きく変える必要はありません。サブスク型の利用枠を前提にした構成なので、API 従量課金だけに依存しない運用がしやすいのも特徴です。

---

## クイックスタート

**1. テンプレートをコピーする**

```bash
./setup.sh --target /path/to/your/repo
```

**2. テンプレートファイルをマージする**

```
CLAUDE.totonoe.template.md  →  対象リポジトリの CLAUDE.md にマージ
AGENTS.totonoe.template.md  →  対象リポジトリの AGENTS.md にマージ
```

**3. エンジニア定義をカスタマイズする**

`.claude/agents/GENERIC-ENGINEER.md` を対象リポジトリの技術スタックに合わせて書き換えます。専門エンジニア（SECURITY-ENGINEER / TEST-ENGINEER / PERF-ENGINEER / REFACTOR-ENGINEER）は必要なものだけ残してください。
標準で含まれる agent には、それぞれの専門性に合わせた判断原則とスタンスがあらかじめ入っています。必要に応じて、対象プロジェクト向けに語調や守備範囲を調整してください。

**4. 環境変数を設定する**

`.env.example` を `.env` にコピーして値を設定します。Gemini の fallback / shadow を使う場合は `GEMINI_API_KEY` を設定してください。

```bash
cp .env.example .env
# .env を編集して必要な値を設定
```

totonoe のスクリプトはリポジトリルートの `.env` を自動で読み込みます。手動で `source .env` を実行する必要はありません。

> **注意**: API キーなどの秘密情報は `.env` に書き、`.totonoe/config.json` には入れないでください。`config.json` にはモード設定など公開可能な情報のみを置きます。`.env` は `.gitignore` で Git 管理から除外されています。

**5. ジョブを初期化してループを開始する**

```bash
# ジョブを作る
.totonoe/bin/init_job.sh \
  --job-name sample-feature \
  --goal-template feature_loop

# ループ用プロンプトを生成して Claude Code に渡す
.totonoe/bin/render_loop_prompt.sh --job-name sample-feature
```

### Claude Code への最初の指示

ジョブを初期化したら、`render_loop_prompt.sh` の出力をそのまま Claude Code に渡してください。
この出力は先頭が `totonoe start` で始まり、Claude Code が loop を開始または再開するための明示トリガーになります。

この出力には、現在の job の目的、対象、必須対応、制約、完了条件、現在状態、次に実行すべき手順が含まれます。
Claude Code はその内容を起点に loop を開始します。

Claude Code に貼り付ける内容の冒頭は次のようになります。
`totonoe start` だけを送るのではなく、このあとに続く出力全文をそのまま貼り付けてください。
以下は読みやすさのために簡略化したサンプルです。実際の `現在状態` には `state.json` の内容が JSON で入ります。

```text
totonoe start
ジョブ名: sample-feature
リポジトリルート: /path/to/repo

目的:
検索フォーム付きの一覧画面を実装し、totonoe を通して品質確認まで完了する。

対象:
- `app/search/page.tsx`
- `components/search-form.tsx`
- 必要なら関連テストと補助コード

必須対応:
- 検索フォームを実装する
- 入力値に応じて一覧を絞り込めるようにする
- summary と quality gate を記録する

制約:
- 無関係な UI 改修を混ぜない
- runtime の state を手動編集しない

完了条件:
- build/test の結果が記録されている
- reviewer / judge / manager のフローを完了している

現在状態:
{
  "current_round": 0,
  "status": "init",
  "last_decision": null
}

次の手順:
1. state を確認する
2. 実装して summary を記録する
3. reviewer と judge を実行する
```

詳しい運用手順は [`RUNBOOK.md`](./.totonoe/RUNBOOK.md) にまとめています。

### 途中で止めたいとき

作業中に急いで止めたい場合は、Claude Code に `totonoe stop` と伝えると、その job を `paused` として停止できます。
`paused` では停止理由と直前の状態が `state.json` に残るため、引き継ぎ時に「どこで止めたか」が分からなくなりにくくなります。

手元で明示的に止める場合:

```bash
.totonoe/bin/pause_job.sh --job-name sample-feature --reason "外出のため一時停止"
```

再開するときは、先に paused 状態を戻してから、もう一度 loop 用プロンプトを生成します。

```bash
.totonoe/bin/resume_job.sh --job-name sample-feature
.totonoe/bin/render_loop_prompt.sh --job-name sample-feature
```

---

## リポジトリ構成

```
.totonoe/           ← ランタイムスクリプト、スキーマ、ゴール、RUNBOOK
  bin/              ← init / status / record / reviewer / judge / manager の各スクリプト
  schemas/          ← Reviewer・Judge の出力スキーマ
  goals/            ← ループのゴールテンプレート
.claude/
  agents/
    MANAGER.md              ← 最終決定者
    GENERIC-ENGINEER.md     ← 汎用エンジニア（デフォルト）
    SECURITY-ENGINEER.md    ← セキュリティ専門
    TEST-ENGINEER.md        ← テスト専門
    PERF-ENGINEER.md        ← パフォーマンス専門
    REFACTOR-ENGINEER.md    ← リファクタリング専門
  settings.json     ← Claude の基本パーミッション設定
.env.example        ← 環境変数の雛形（.env にコピーして使う）
CLAUDE.totonoe.template.md
AGENTS.totonoe.template.md
gitignore.additions
setup.sh
```

---

## エンジニアの専門分野ルーティング

Analyst が `judge.json` に `engineer_type` を返した場合、Manager はその推奨を参考に対応するエンジニアを選びます。ただし推奨であって強制ではなく、Manager が内容を見て判断を変えることができます。

| `engineer_type`        | 呼び出されるエンジニア |
| ---------------------- | ---------------------- |
| `security`             | Security-Engineer      |
| `test`                 | Test-Engineer          |
| `performance`          | Perf-Engineer          |
| `refactor`             | Refactor-Engineer      |
| `generic` または未設定 | Generic-Engineer       |

分類が曖昧な場合や修正が複数カテゴリにまたがる場合は、Generic-Engineer を使うのが安全です。

---

## Gemini の扱いについて

Gemini は fallback / shadow 用の optional provider です。`GEMINI_API_KEY` がなくても Codex-only で通常運用できます。利用する場合は、秘密情報の管理を厳格に分離しています。

- API キーは `.env` に書き、環境変数（`GEMINI_API_KEY`）として読み込みます。`config.json` や Git 管理されるファイルには入れません
- `.totonoe/config.json` には provider のモードなど公開可能な設定のみを置きます
- 既定モデルは `gemini-2.5-flash-lite` です。利用可能なトークン量が最も多いモデルをデフォルトとして採用しています。ご自身の project / tier に合わせて変更してください
- Gemini は fallback または shadow の用途で使い、Codex（primary）を置き換えるものではありません
- `GEMINI_API_KEY` が未設定の状態で Gemini が必要な処理に到達すると、スクリプトは明示的にエラーで止まります

---

## totonoe の Shadow Mode について

`config.json` で `reviewer.mode: "shadow"` を設定すると、totonoe の Shadow Mode が有効になります。

通常の fallback モードでは Codex が使えないときだけ Gemini に切り替えますが、Shadow Mode では原則として Codex（primary）と Gemini（shadow）を両方動かし、比較用の結果を round ディレクトリに保存します。ただし primary が Gemini fallback を使った batch では shadow を自動スキップします（Gemini 対 Gemini の比較に観測価値がないため）。`done` 判定や state 遷移には primary（Codex）の結果だけを使います。

目的は「どちらが何を見落とすか」を観測することです。将来的に両者の評価を正式採用する consensus mode への布石として位置づけています。

Shadow Mode の注意点:

- primary が Gemini fallback を使った batch では、shadow 実行を自動スキップします。Gemini 対 Gemini の比較には観測価値がないためです
- shadow 比較は batch ごとに `success` / `skipped` / `failed` がありえます。各 round の `reviewer_shadow_status.json` で確認できます
- shadow mode は比較観測機能であり、主系判定には常に primary の結果を使います。shadow の失敗や欠損で loop が止まることはありません

---

## Claude Code の実行モードについて

`totonoe` の長時間ループ運用では、隔離された開発環境に限り `claude --dangerously-skip-permissions` の利用を推奨します。

`totonoe` は複数の定型スクリプトを連続実行する構成のため、`claude --permission-mode acceptEdits` のような控えめなモードでも確認ダイアログは残りやすく、長いループでは途中停止が発生しがちです。一方で `--dangerously-skip-permissions` は権限確認を省略できるため、review / judge / manager の流れを中断せずに回しやすくなります。

ただし、これは安全な隔離環境で使うことを前提とします。普段使いの開発マシンや、本番 credential・個人ファイルにアクセスできる環境では推奨しません。

- 推奨: devcontainer / VM / 検証用ワークスペース
- 非推奨: 本番 credential を持つローカル環境
- `claude --permission-mode acceptEdits` は、より保守的に動かしたい場合の代替案です

---

## 実験的機能について

`.claude/settings.json` で `agentTeams` フラグを有効にしています。これは Claude Code の実験的機能で、将来変更される可能性があります。

---

## セキュリティ

ランタイム層ではパスの正規化、symlink チェック、アトミック書き込みなどセキュリティに関わる設計判断を多く行っています。派生リポジトリを公開する前に [`SECURITY.md`](./SECURITY.md) を一読してください。

---

## CI

基本的な CI チェックを含んでいます。

- `bash -n` によるシェル構文の検証
- JSON スキーマのパース確認
- `setup.sh` のスモークテスト
- ジョブ初期化・ラウンド記録のスモークテスト

詳細は [`.github/workflows/ci.yml`](./.github/workflows/ci.yml) を参照してください。

---

## ライセンス

MIT — [`LICENSE`](./LICENSE) を参照してください。
