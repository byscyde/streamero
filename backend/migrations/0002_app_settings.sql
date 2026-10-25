-- Remote app configuration (appearance, texts, feature flags). One JSON document per key; the API
-- merges the stored document over built-in defaults, so rows only hold what an admin changed.
CREATE TABLE app_settings (
  key         text PRIMARY KEY,
  value       jsonb NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid REFERENCES users(id) ON DELETE SET NULL
);
