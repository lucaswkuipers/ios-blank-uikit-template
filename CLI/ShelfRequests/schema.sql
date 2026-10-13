CREATE TABLE IF NOT EXISTS requests (
  id TEXT PRIMARY KEY,
  udid TEXT NOT NULL UNIQUE,
  device_name TEXT NOT NULL,
  model TEXT NOT NULL,
  system_version TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
