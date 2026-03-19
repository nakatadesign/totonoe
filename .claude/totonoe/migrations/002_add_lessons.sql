-- totonoe knowledge database schema addition
-- Version: 002 — lessons テーブル追加

---------------------------------------------
-- 5. lessons: ジョブ完了時の教訓
-- 1 ジョブ 1 教訓（UNIQUE(job_name)）
-- learn.sh が done 確定時に書き込む
---------------------------------------------
CREATE TABLE IF NOT EXISTS lessons (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    job_name    TEXT    NOT NULL UNIQUE,
    lesson      TEXT    NOT NULL,
    created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_lessons_job ON lessons(job_name);

INSERT OR IGNORE INTO schema_version (version) VALUES (2);
