-- =============================================================================
-- StageDB · 00_extensions.sql
-- Extensions used by the schema. All ship with standard PostgreSQL (contrib).
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS citext;      -- case-insensitive email addresses
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- lets EXCLUDE constraints mix "=" with range "&&"
CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- trigram index for fuzzy event search

CREATE SCHEMA IF NOT EXISTS ticketing;
COMMENT ON SCHEMA ticketing IS 'StageDB: event ticketing & seat reservation system';
