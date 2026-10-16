-- Database schema for the ML Text Classifier Service workflow (PostgreSQL 13+)
-- Run once before activating the n8n workflow, then optionally run seed_examples.sql.

-- ---------------------------------------------------------------
-- Labeled training examples
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS examples (
    id         SERIAL PRIMARY KEY,
    text       TEXT        NOT NULL CHECK (length(text) BETWEEN 1 AND 2000),
    label      TEXT        NOT NULL CHECK (length(label) BETWEEN 1 AND 50),
    source     TEXT        NOT NULL DEFAULT 'bulk' CHECK (source IN ('bulk', 'feedback', 'seed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- one label per distinct text; the latest label wins
    text_hash  TEXT GENERATED ALWAYS AS (md5(text)) STORED
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_examples_text_hash ON examples (text_hash);
CREATE INDEX IF NOT EXISTS idx_examples_label ON examples (label);

-- ---------------------------------------------------------------
-- Trained models (every training run is recorded, only promoted ones keep the model blob)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS models (
    id               SERIAL PRIMARY KEY,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    n_train          INTEGER     NOT NULL,
    n_test           INTEGER     NOT NULL,
    classes          TEXT[]      NOT NULL,
    metrics          JSONB       NOT NULL,            -- accuracy, macro F1, per-class scores on the holdout
    champion_metrics JSONB,                           -- the serving model, evaluated on the same holdout
    promoted         BOOLEAN     NOT NULL,
    reason           TEXT        NOT NULL,
    model            JSONB                            -- NULL when the model was not promoted
);

-- ---------------------------------------------------------------
-- Pointer to the serving model (exactly one row). Promotion is a single atomic statement.
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS active_model (
    singleton   BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    model_id    INTEGER     NOT NULL REFERENCES models (id),
    promoted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------
-- Predictions served, with optional human feedback
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS predictions (
    id             BIGSERIAL PRIMARY KEY,
    model_id       INTEGER     NOT NULL REFERENCES models (id),
    text           TEXT        NOT NULL,              -- truncated to 2000 characters
    label          TEXT,                              -- NULL when the text had no known words
    confidence     NUMERIC(5,4) NOT NULL,
    low_confidence BOOLEAN     NOT NULL,
    probs          JSONB       NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    feedback_label TEXT,
    feedback_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_predictions_created  ON predictions (created_at);
CREATE INDEX IF NOT EXISTS idx_predictions_feedback ON predictions (feedback_at) WHERE feedback_label IS NOT NULL;

-- ---------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW model_history AS
SELECT id, created_at, n_train, n_test, promoted, reason,
       (metrics->>'accuracy')::numeric  AS accuracy,
       (metrics->>'macro_f1')::numeric  AS macro_f1,
       (champion_metrics->>'macro_f1')::numeric AS champion_macro_f1
FROM models ORDER BY id DESC;

CREATE OR REPLACE VIEW label_counts AS
SELECT label, COUNT(*) AS examples FROM examples GROUP BY label ORDER BY examples DESC;
