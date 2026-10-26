-- Google sign-in replaces Sign in with Apple. apple_sub is kept (no data is dropped) but no longer used.
ALTER TABLE users ADD COLUMN IF NOT EXISTS google_sub text UNIQUE;
