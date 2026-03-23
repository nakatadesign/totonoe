CREATE TABLE IF NOT EXISTS lesson_entries (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    job_name     TEXT    NOT NULL,
    kind         TEXT    NOT NULL CHECK (kind IN (
                     'review_pattern',
                     'failed_attempt',
                     'done_condition',
                     'human_escalation_reason'
                 )),
    content      TEXT    NOT NULL,
    round        INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_lesson_entries_job_kind
    ON lesson_entries (job_name, kind);

INSERT OR IGNORE INTO schema_version (version) VALUES (3);
