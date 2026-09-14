ALTER TABLE providers ADD COLUMN model_mode TEXT NOT NULL DEFAULT 'automatic' CHECK (model_mode IN ('automatic', 'manual'));
ALTER TABLE providers ADD COLUMN gateway TEXT CHECK (gateway IS NULL OR json_valid(gateway));
ALTER TABLE providers ADD COLUMN header_credentials_encrypted TEXT;
