CREATE TABLE IF NOT EXISTS requests (
  id TEXT PRIMARY KEY,
  udid TEXT NOT NULL,
  device_name TEXT NOT NULL,
  model TEXT NOT NULL,
  system_version TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS open_request ON requests (udid) WHERE status IN ('pending', 'waiting');

CREATE TABLE IF NOT EXISTS invites (
  token TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  profile TEXT NOT NULL,
  request TEXT,
  created_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS invite_request ON invites (request) WHERE request IS NOT NULL;

CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
