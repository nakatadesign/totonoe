-- totonoe knowledge database schema
-- Version: 001

PRAGMA journal_mode = WAL;

---------------------------------------------
-- 1. review_rounds: Reviewer のラウンド単位集約
-- findings が 0 件の良いレビュー（overall_grade=S）も記録できる設計
-- 品質フィルタ: run_reviewer.sh がグレード S/A のラウンドのみ INSERT する
--              初期蓄積フェーズ（20件未満）は B 以上を許可する
---------------------------------------------
CREATE TABLE IF NOT EXISTS review_rounds (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    job_name       TEXT    NOT NULL,
    round          INTEGER NOT NULL,
    overall_grade  TEXT    NOT NULL CHECK (overall_grade IN ('S', 'A', 'B', 'C')),
    critical_count INTEGER NOT NULL DEFAULT 0,
    summary        TEXT    NOT NULL,
    created_at     TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),

    UNIQUE(job_name, round)
);

CREATE INDEX IF NOT EXISTS idx_review_rounds_job   ON review_rounds(job_name);
CREATE INDEX IF NOT EXISTS idx_review_rounds_grade ON review_rounds(overall_grade);

---------------------------------------------
-- 2. review_findings: findings を行単位で正規化
-- review_rounds と 1:N の関係
-- category は実装スキーマに存在しないため持たない
-- 検索は severity / file / title / reason を基準に行う
---------------------------------------------
CREATE TABLE IF NOT EXISTS review_findings (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    review_round_id INTEGER NOT NULL REFERENCES review_rounds(id) ON DELETE CASCADE,
    job_name        TEXT    NOT NULL,
    round           INTEGER NOT NULL,
    file            TEXT,
    severity        TEXT    NOT NULL CHECK (severity IN ('critical', 'high', 'medium', 'low')),
    title           TEXT    NOT NULL,
    reason          TEXT    NOT NULL,
    suggested_fix   TEXT,
    resolved        INTEGER NOT NULL DEFAULT 0,  -- 0: 未解決, 1: 解消済み
    created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_review_findings_round_id ON review_findings(review_round_id);
CREATE INDEX IF NOT EXISTS idx_review_findings_job      ON review_findings(job_name);
CREATE INDEX IF NOT EXISTS idx_review_findings_severity ON review_findings(severity);
CREATE INDEX IF NOT EXISTS idx_review_findings_resolved ON review_findings(resolved);

---------------------------------------------
-- 3. verdicts: Judge の判定履歴
-- recommendation は run_judge.sh の実装値に合わせる
-- confidence は judge.json に存在しないため持たない
---------------------------------------------
CREATE TABLE IF NOT EXISTS verdicts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    job_name        TEXT    NOT NULL,
    round           INTEGER NOT NULL,
    recommendation  TEXT    NOT NULL CHECK (recommendation IN ('fix', 'continue', 'done', 'human')),
    engineer_type   TEXT    DEFAULT 'generic',
    reason          TEXT    NOT NULL,
    created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),

    UNIQUE(job_name, round)
);

CREATE INDEX IF NOT EXISTS idx_verdicts_job            ON verdicts(job_name);
CREATE INDEX IF NOT EXISTS idx_verdicts_recommendation ON verdicts(recommendation);
CREATE INDEX IF NOT EXISTS idx_verdicts_engineer_type  ON verdicts(engineer_type);

---------------------------------------------
-- 4. schema_version: マイグレーション管理
---------------------------------------------
CREATE TABLE IF NOT EXISTS schema_version (
    version     INTEGER PRIMARY KEY,
    applied_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT OR IGNORE INTO schema_version (version) VALUES (1);
