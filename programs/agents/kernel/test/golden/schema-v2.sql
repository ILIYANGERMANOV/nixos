CREATE TABLE runs (
  -- One row per run. A write-once index of the run's first event (started),
  -- inserted in that event's transaction. Never updated, never deleted.

  -- The run's id, as state init made it. An event prints as <id>:<seq>, so an id holds no colon.
  id            TEXT NOT NULL PRIMARY KEY
                CONSTRAINT runs_id_format CHECK (id <> '' AND instr(id, ':') = 0),
  -- The run that started this one. Optional: a top-level run has no parent.
  parent_run_id TEXT REFERENCES runs (id)
                CONSTRAINT runs_parent_run_id_not_self CHECK (parent_run_id IS NOT id),
  -- The flow the run follows: engineer, 10x, architect or chief today.
  -- Open text on purpose: a CHECK here could never change. The codec is its one parser.
  flow          TEXT NOT NULL,
  -- The directory that holds the run's notes, as given to state init. The store finds a run by it.
  notes_dir     TEXT NOT NULL,
  -- The time of the started event: the kernel's clock at append.
  -- RFC 3339 profile: UTC, uppercase T and Z, exactly 3 fraction digits. Text order is time order.
  created_at    TEXT NOT NULL
                CONSTRAINT runs_created_at_format CHECK (
                  length(created_at) = 24
                  AND created_at IS strftime('%Y-%m-%dT%H:%M:%fZ', created_at, '+0 seconds'))
) STRICT;
CREATE INDEX runs_parent_run_id_idx ON runs (parent_run_id);
CREATE INDEX runs_notes_dir_idx ON runs (notes_dir);
CREATE TABLE events (
  -- The log: one row per event, append-only. The only truth.
  -- Every table below blobs is rebuilt from these rows.

  -- The order of appends across all runs. SQLite sets it: the writer never does.
  -- The event-store word is global_position.
  position       INTEGER PRIMARY KEY,
  -- The run this event belongs to. CloudEvents source.
  run_id         TEXT    NOT NULL REFERENCES runs (id),
  -- The event's place inside its run: dense from 1, checked by the writer.
  -- CloudEvents sequence. The event's id is <run_id>:<seq>.
  seq            INTEGER NOT NULL
                 CONSTRAINT events_seq_positive CHECK (seq >= 1),
  -- The version of this event type's payload, from 1. A change of shape bumps it.
  schema_version INTEGER NOT NULL
                 CONSTRAINT events_schema_version_positive CHECK (schema_version >= 1),
  -- What happened. CloudEvents type: a fixed name such as asked, or <step>.<outcome>.
  -- Open text on purpose: flows add steps, and a CHECK here could never change.
  type           TEXT    NOT NULL
                 CONSTRAINT events_type_not_empty CHECK (type <> ''),
  -- CloudEvents time: the kernel's clock at append, for every event.
  -- RFC 3339 profile: UTC, uppercase T and Z, exactly 3 fraction digits. Text order is time order.
  time           TEXT    NOT NULL
                 CONSTRAINT events_time_format CHECK (
                   length(time) = 24
                   AND time IS strftime('%Y-%m-%dT%H:%M:%fZ', time, '+0 seconds')),
  -- The harness session that wrote the event. Optional: a plain shell has no session.
  session_id     TEXT
                 CONSTRAINT events_session_id_not_empty CHECK (session_id IS NOT ''),
  -- The commit the worktree was at. Optional: a repo with no commit yet has none.
  -- A git object id: 40 (SHA-1) or 64 (SHA-256) lowercase hex.
  head_sha       TEXT
                 CONSTRAINT events_head_sha_format CHECK (
                   head_sha IS NULL
                   OR (length(head_sha) IN (40, 64) AND head_sha NOT GLOB '*[^0-9a-f]*')),
  -- The dedupe key of an event a hook wrote: FNV-1a 64, 16 lowercase hex, zero padded.
  -- NULL means a CLI line. A hook that fires twice appends once.
  hook_digest    TEXT
                 CONSTRAINT events_hook_digest_format CHECK (
                   hook_digest IS NULL
                   OR (length(hook_digest) = 16 AND hook_digest NOT GLOB '*[^0-9a-f]*')),
  -- CloudEvents data: the payload, one JSON object (I-JSON). Its keys depend on type.
  -- A union inside it carries one tag key, kind.
  data           TEXT    NOT NULL
                 CONSTRAINT events_data_json_object CHECK (json_valid(data) AND json_type(data) = 'object'),
  UNIQUE (run_id, seq),
  UNIQUE (run_id, hook_digest)
) STRICT;
CREATE INDEX events_type_idx ON events (type);
CREATE INDEX events_session_id_idx ON events (session_id);
CREATE TABLE blobs (
  -- The content of registered files, stored once per content. Append-only.
  -- An artifact event names a file by path and sha256. The file's bytes live here
  -- when the writer snapshots them (files up to 1048576 bytes; the cap lives in the writer).

  -- SHA-256 of content: 64 lowercase hex. The OCI digest without its sha256: prefix.
  sha256     TEXT    NOT NULL PRIMARY KEY
             CONSTRAINT blobs_sha256_format CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
  -- The length of content in bytes. OCI size. Kept beside content for the OCI mapping.
  size_bytes INTEGER NOT NULL,
  -- The file's bytes, as read once at registration. OCI data.
  content    BLOB    NOT NULL,
  CONSTRAINT blobs_size_bytes_matches_content CHECK (size_bytes = length(content))
) STRICT;
CREATE TRIGGER runs_no_update BEFORE UPDATE ON runs
BEGIN SELECT RAISE(ABORT, 'runs is append-only: a run never changes'); END;
CREATE TRIGGER runs_no_delete BEFORE DELETE ON runs
BEGIN SELECT RAISE(ABORT, 'runs is append-only: a run is never deleted'); END;
CREATE TRIGGER events_no_update BEFORE UPDATE ON events
BEGIN SELECT RAISE(ABORT, 'events is append-only: log a new event'); END;
CREATE TRIGGER events_no_delete BEFORE DELETE ON events
BEGIN SELECT RAISE(ABORT, 'events is append-only: void a line with state void'); END;
CREATE TRIGGER blobs_no_update BEFORE UPDATE ON blobs
BEGIN SELECT RAISE(ABORT, 'blobs is append-only: new content is a new row'); END;
CREATE TRIGGER blobs_no_delete BEFORE DELETE ON blobs
BEGIN SELECT RAISE(ABORT, 'blobs is append-only: content is never deleted'); END;
