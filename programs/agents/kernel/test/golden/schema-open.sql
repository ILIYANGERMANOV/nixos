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
CREATE TABLE projection_versions (
  -- One row per projection module. Every projection is dropped, recreated and refolded
  -- when any one's DDL text differs from sqlite_schema.sql, or its version here from the kernel's.

  -- The projection module's name, such as tasks or questions.
  name    TEXT    NOT NULL PRIMARY KEY,
  -- The version of the module's rows function, from 1. Bumped by hand when the rows change.
  version INTEGER NOT NULL
          CONSTRAINT projection_versions_version_positive CHECK (version >= 1)
) STRICT;
CREATE TABLE run_states (
  -- Where a run stands now. One row per run.

  -- The run.
  run_id      TEXT NOT NULL PRIMARY KEY REFERENCES runs (id),
  -- active: the flow goes on. stopped: a stop event ended it. finished: the flow reached its end.
  status      TEXT NOT NULL
              CONSTRAINT run_states_status_enum CHECK (status IN ('active', 'stopped', 'finished')),
  -- The flow state the run is at, such as review or gather/researchers. out or exit once finished.
  step        TEXT NOT NULL,
  -- Why the run stopped. Set only when stopped.
  stop_reason TEXT
              CONSTRAINT run_states_stop_reason_enum CHECK (stop_reason IN ('blocked', 'failed', 'replan', 'rounds')),
  -- The stop's own words. Set only when stopped.
  stop_detail TEXT,
  -- The run's Fuel: how many tokens and how much time it may spend. balanced until a fuel.set event.
  fuel        TEXT NOT NULL
              CONSTRAINT run_states_fuel_enum CHECK (fuel IN ('low', 'balanced', 'max')),
  -- The user's goal, word for word, from the started event. Optional: a run started with none has none.
  goal        TEXT,
  -- The git worktree the run works in: an absolute path. The latest worktree_moved event wins.
  worktree    TEXT NOT NULL,
  -- The repository the run works in, as owner/name. Optional: a worktree with no GitHub remote has none.
  repo        TEXT,
  -- The run's own pull request. Optional: none before the draft.
  pr_url      TEXT,
  -- The branch the run's pull request targets. Optional: none before the draft.
  base_branch TEXT,
  -- The branch the run's pull request comes from. Optional: none before the draft.
  head_branch TEXT,
  -- The ticket the run wrote. Optional: most runs write none.
  ticket_url  TEXT,
  CONSTRAINT run_states_stop_reason_iff_stopped CHECK ((stop_reason IS NOT NULL) = (status = 'stopped')),
  CONSTRAINT run_states_stop_detail_iff_stopped CHECK ((stop_detail IS NOT NULL) = (status = 'stopped'))
) STRICT;
CREATE TABLE step_visits (
  -- Each stay of a run at one flow state, in order. A loop visits a state again: a new row.

  -- The run.
  run_id     TEXT    NOT NULL REFERENCES runs (id),
  -- The seq of the event that moved the run into the state.
  id         INTEGER NOT NULL,
  -- The flow state's name, such as plan or gather/notes.
  step       TEXT    NOT NULL,
  -- The time of the event that moved the run in.
  entered_at TEXT    NOT NULL,
  -- The time of the event that moved the run on. NULL: the run is here now.
  left_at    TEXT,
  PRIMARY KEY (run_id, id),
  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq)
) STRICT;
CREATE TABLE loop_rounds (
  -- Each round of a flow loop a run went through, such as a review round or a CI fix round.

  -- The run.
  run_id  TEXT    NOT NULL REFERENCES runs (id),
  -- The loop's name in the flow: plan, gather, fix, ci or round.
  loop    TEXT    NOT NULL,
  -- The seq of the event that opened this round. One event can open a round of several loops.
  id      INTEGER NOT NULL,
  -- The round's number inside this pass through the loop, from 1.
  ordinal INTEGER NOT NULL,
  PRIMARY KEY (run_id, loop, id),
  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq)
) STRICT;
CREATE TABLE round_problems (
  -- What was still wrong in a loop round. The same problems two rounds in a row mean the run is stuck.

  -- The run.
  run_id        TEXT    NOT NULL REFERENCES runs (id),
  -- The loop of the round.
  loop          TEXT    NOT NULL,
  -- The round: loop_rounds.id.
  loop_round_id INTEGER NOT NULL,
  -- row: a review finding picked to fix. unmet: a requirement judged not met. failing: a red CI check.
  kind          TEXT    NOT NULL
                CONSTRAINT round_problems_kind_enum CHECK (kind IN ('row', 'unmet', 'failing')),
  -- The finding's label, the requirement's text or the check's name.
  name          TEXT    NOT NULL,
  PRIMARY KEY (run_id, loop, loop_round_id, kind, name),
  FOREIGN KEY (run_id, loop, loop_round_id) REFERENCES loop_rounds (run_id, loop, id)
) STRICT;
CREATE TABLE breakdowns (
  -- Each task list a 10x run recorded. A new breakdown starts a fresh set of tasks:
  -- the newest one is current, older ones stay as history.

  -- The run.
  run_id TEXT    NOT NULL REFERENCES runs (id),
  -- The seq of the breakdown.done event.
  id     INTEGER NOT NULL,
  -- The name of the fan-out the breakdown fills. engineers today.
  fan    TEXT    NOT NULL,
  PRIMARY KEY (run_id, id),
  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq)
) STRICT;
CREATE TABLE epics (
  -- A shared branch that several task pull requests target, joined to the default branch by one final pull request.

  -- The run.
  run_id TEXT NOT NULL REFERENCES runs (id),
  -- The epic's name, unique in the run.
  name   TEXT NOT NULL,
  -- The repository that holds the branch, as owner/name.
  repo   TEXT NOT NULL,
  -- The shared branch, such as epic/rate-limits.
  branch TEXT NOT NULL,
  -- open: tasks still land on the branch. ready_for_review: its final pull request is up. merged: the user merged it.
  status TEXT NOT NULL
         CONSTRAINT epics_status_enum CHECK (status IN ('open', 'ready_for_review', 'merged')),
  -- The final pull request. Set once ready_for_review, kept when merged.
  pr_url TEXT,
  PRIMARY KEY (run_id, name),
  CONSTRAINT epics_pr_url_iff_ready_or_merged CHECK ((pr_url IS NOT NULL) = (status IN ('ready_for_review', 'merged')))
) STRICT;
CREATE TABLE tasks (
  -- One unit of a breakdown: one deliverable, one pull request, at most one agent at a time.
  -- Fields only a brief reads (fuel, qa, heavy, security, shape, plan, flow, worktree)
  -- stay in the breakdown.done or task_added event.

  -- The run.
  run_id        TEXT    NOT NULL REFERENCES runs (id),
  -- The breakdown the task belongs to. A task id is unique inside one breakdown only.
  breakdown_id  INTEGER NOT NULL,
  -- The task's id as the breakdown names it, such as t4.
  id            TEXT    NOT NULL,
  -- One line that says what the task delivers.
  title         TEXT    NOT NULL,
  -- The repository the task works in, as owner/name. Optional: a breakdown may leave it out.
  repo          TEXT,
  -- What the task's pull request targets.
  -- on_default: the default branch. on_epic: an epic's branch. on_task: another task's branch (stacked).
  base_kind     TEXT    NOT NULL
                CONSTRAINT tasks_base_kind_enum CHECK (base_kind IN ('on_default', 'on_epic', 'on_task')),
  -- The epic the task targets. Set only when on_epic.
  base_epic_name TEXT,
  -- The task this one is stacked on, in the same breakdown. Set only when on_task.
  base_task_id  TEXT,
  -- The branch the task's pull request comes from.
  head_branch   TEXT    NOT NULL,
  -- The task's pull request. Optional: none before the first one is recorded.
  pr_url        TEXT,
  -- The latest commit recorded on the pull request. Optional: none before the first task_head event.
  head_sha      TEXT,
  -- planned: no agent yet. running: an agent has it and no pull request state is recorded.
  -- in_ci: the pull request waits on CI. in_review: it waits on the user's review.
  -- round: more work on the same pull request. merged: done. kept: a round's pull request left open on purpose.
  -- parked: set aside, with a reason. delivered: done as the run's rules define it, its pull request left open.
  status        TEXT    NOT NULL
                CONSTRAINT tasks_status_enum CHECK (
                  status IN ('planned', 'running', 'in_ci', 'in_review', 'round', 'merged', 'kept', 'parked', 'delivered')),
  -- Why the task is parked. Set only when parked.
  parked_reason TEXT,
  -- 1 while an agent works on the task, else 0. Its own fact: a task in_ci can have a fixer at work.
  at_work       INTEGER NOT NULL
                CONSTRAINT tasks_at_work_boolean CHECK (at_work IN (0, 1)),
  PRIMARY KEY (run_id, breakdown_id, id),
  FOREIGN KEY (run_id, breakdown_id) REFERENCES breakdowns (run_id, id),
  FOREIGN KEY (run_id, base_epic_name) REFERENCES epics (run_id, name),
  FOREIGN KEY (run_id, breakdown_id, base_task_id) REFERENCES tasks (run_id, breakdown_id, id),
  CONSTRAINT tasks_base_epic_name_iff_on_epic CHECK ((base_epic_name IS NOT NULL) = (base_kind = 'on_epic')),
  CONSTRAINT tasks_base_task_id_iff_on_task CHECK ((base_task_id IS NOT NULL) = (base_kind = 'on_task')),
  CONSTRAINT tasks_base_task_id_not_self CHECK (base_task_id IS NOT id),
  CONSTRAINT tasks_parked_reason_iff_parked CHECK ((parked_reason IS NOT NULL) = (status = 'parked')),
  CONSTRAINT tasks_pr_url_required_by_status CHECK (
    status NOT IN ('in_ci', 'in_review', 'round', 'merged', 'kept', 'delivered') OR pr_url IS NOT NULL),
  CONSTRAINT tasks_at_work_never_planned_or_parked CHECK (at_work = 0 OR status NOT IN ('planned', 'parked'))
) STRICT;
CREATE TABLE task_dependencies (
  -- An ordering edge: a task starts only after another one of its breakdown is merged.

  -- The run.
  run_id        TEXT    NOT NULL REFERENCES runs (id),
  -- The breakdown both tasks belong to.
  breakdown_id  INTEGER NOT NULL,
  -- The task that waits.
  task_id       TEXT    NOT NULL,
  -- The task it waits for.
  after_task_id TEXT    NOT NULL,
  PRIMARY KEY (run_id, breakdown_id, task_id, after_task_id),
  FOREIGN KEY (run_id, breakdown_id, task_id) REFERENCES tasks (run_id, breakdown_id, id),
  FOREIGN KEY (run_id, breakdown_id, after_task_id) REFERENCES tasks (run_id, breakdown_id, id),
  CONSTRAINT task_dependencies_after_task_id_not_self CHECK (after_task_id <> task_id)
) STRICT;
CREATE TABLE child_runs (
  -- One row per child run that a run's fan-out spawned. A task can have several over time:
  -- the first, one per round, a retry. A child started outside a fan-out has no row here:
  -- runs.parent_run_id links it.

  -- The parent run.
  run_id         TEXT    NOT NULL REFERENCES runs (id),
  -- The seq of the spawned event in the parent's log.
  id             INTEGER NOT NULL,
  -- The child run. Its notes dir is runs.notes_dir, its state is its own run_states row.
  child_run_id   TEXT    NOT NULL REFERENCES runs (id),
  -- The breakdown of the child's task. Optional: an untasked child has none.
  breakdown_id   INTEGER,
  -- The task the child works on. Optional: an untasked child has none.
  task_id        TEXT,
  -- The git worktree the child started in: an absolute path. A later move is in the child's own run_states row.
  worktree       TEXT    NOT NULL,
  -- The token of the child's latest hand-back. NULL: it has not handed back yet,
  -- or it stopped to re-plan or out of rounds, or the run triaged its stop.
  handback_token TEXT
                 CONSTRAINT child_runs_handback_token_enum CHECK (
                   handback_token IN ('ready', 'needs_decision', 'await', 'blocked', 'failed')),
  PRIMARY KEY (run_id, id),
  UNIQUE (run_id, child_run_id),
  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq),
  FOREIGN KEY (run_id, breakdown_id, task_id) REFERENCES tasks (run_id, breakdown_id, id),
  CONSTRAINT child_runs_task_id_iff_breakdown_id CHECK ((task_id IS NULL) = (breakdown_id IS NULL))
) STRICT;
CREATE TABLE task_holds (
  -- A wake held back while a task's agent was at work: a review, a comment or a check at a URL.
  -- The lead acts on it after the agent hands back.

  -- The run.
  run_id       TEXT    NOT NULL REFERENCES runs (id),
  -- The seq of the held event.
  id           INTEGER NOT NULL,
  -- The breakdown of the task.
  breakdown_id INTEGER NOT NULL,
  -- The task the wake is for.
  task_id      TEXT    NOT NULL,
  -- Where the held finding is. Compared as a plain string.
  url          TEXT    NOT NULL,
  -- open: still held. acted: an acted event named the same task and url.
  status       TEXT    NOT NULL
               CONSTRAINT task_holds_status_enum CHECK (status IN ('open', 'acted')),
  PRIMARY KEY (run_id, id),
  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq),
  FOREIGN KEY (run_id, breakdown_id, task_id) REFERENCES tasks (run_id, breakdown_id, id)
) STRICT;
CREATE TABLE questions (
  -- One row per question a run has to settle: its own, or one a child run handed up.

  -- The run that holds the question.
  run_id             TEXT    NOT NULL REFERENCES runs (id),
  -- The seq of this run's asked event.
  id                 INTEGER NOT NULL,
  -- The run that first asked the question. This run, for its own question.
  origin_run_id      TEXT    NOT NULL,
  -- The seq of the first asked event, in origin_run_id's log.
  -- The question's one identity, printed as <origin_run_id>:<origin_question_id>.
  origin_question_id INTEGER NOT NULL,
  -- What sort of decision it is. It decides who may answer.
  kind               TEXT    NOT NULL
                     CONSTRAINT questions_kind_enum CHECK (
                       kind IN ('fact', 'pick', 'design', 'scope', 'confirm', 'security', 'stuck')),
  -- The question, one line.
  text               TEXT    NOT NULL,
  -- The flow state the run was at when the question was asked.
  step               TEXT    NOT NULL,
  -- Who put the question to this run. self: its lead. subagent: a worker. child_run: a child run.
  asker_kind         TEXT    NOT NULL
                     CONSTRAINT questions_asker_kind_enum CHECK (asker_kind IN ('self', 'subagent', 'child_run')),
  -- The worker's role. Set only when subagent.
  asker_role         TEXT,
  -- The child run that handed the question up. Set only when child_run.
  asker_run_id       TEXT    REFERENCES runs (id),
  -- in_triage: the run must rule or forward. awaiting_answer: forwarded up, no answer yet.
  -- parked: waits for a later answer. ruled: this run ruled. answered: an answer came down.
  -- A question a stop ended keeps the status it last had.
  status             TEXT    NOT NULL
                     CONSTRAINT questions_status_enum CHECK (
                       status IN ('in_triage', 'awaiting_answer', 'parked', 'ruled', 'answered')),
  -- Why the question is parked. Set only when parked.
  parked_reason      TEXT,
  PRIMARY KEY (run_id, id),
  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq),
  FOREIGN KEY (origin_run_id, origin_question_id) REFERENCES events (run_id, seq),
  CONSTRAINT questions_asker_role_iff_subagent CHECK ((asker_role IS NOT NULL) = (asker_kind = 'subagent')),
  CONSTRAINT questions_asker_run_id_iff_child_run CHECK ((asker_run_id IS NOT NULL) = (asker_kind = 'child_run')),
  CONSTRAINT questions_parked_reason_iff_parked CHECK ((parked_reason IS NOT NULL) = (status = 'parked'))
) STRICT;
CREATE TABLE rulings (
  -- A run's own decision on a question. At most one per question.

  -- The run that ruled.
  run_id          TEXT    NOT NULL REFERENCES runs (id),
  -- The question: questions.id.
  question_id     INTEGER NOT NULL,
  -- What was decided, one line.
  answer          TEXT    NOT NULL,
  -- Why, one line.
  reason          TEXT    NOT NULL,
  -- What the decision costs, one line.
  cost            TEXT    NOT NULL,
  -- What the ruling rests on. none: nothing named. event: an earlier event. obvious: a stated reason.
  basis_kind      TEXT    NOT NULL
                  CONSTRAINT rulings_basis_kind_enum CHECK (basis_kind IN ('none', 'event', 'obvious')),
  -- The run of the event the ruling rests on. Set only when event.
  -- No foreign key: the lead typed the reference, and the command checks it.
  -- NULL with event: a hook's event no line of the run holds.
  basis_event_run_id TEXT,
  -- The seq of that event. Set only when event.
  basis_event_seq INTEGER,
  -- Why the answer is obvious. Set only when obvious.
  basis_reason    TEXT,
  PRIMARY KEY (run_id, question_id),
  FOREIGN KEY (run_id, question_id) REFERENCES questions (run_id, id),
  CONSTRAINT rulings_basis_event_run_id_only_event CHECK (basis_event_run_id IS NULL OR basis_kind = 'event'),
  CONSTRAINT rulings_basis_event_seq_only_event CHECK (basis_event_seq IS NULL OR basis_kind = 'event'),
  CONSTRAINT rulings_basis_reason_iff_obvious CHECK ((basis_reason IS NOT NULL) = (basis_kind = 'obvious'))
) STRICT;
CREATE TABLE answers (
  -- The answer that came down to a forwarded question. At most one per question.

  -- The run that got the answer.
  run_id          TEXT    NOT NULL REFERENCES runs (id),
  -- The question: questions.id.
  question_id     INTEGER NOT NULL,
  -- The answer's text.
  answer          TEXT    NOT NULL,
  -- chose: one of the offered options. other: the answerer's own words.
  reply_kind      TEXT    NOT NULL
                  CONSTRAINT answers_reply_kind_enum CHECK (reply_kind IN ('chose', 'other')),
  -- Who answered. user: the person. parent_run: the run above. caller: the agent that spawned this lead.
  answerer_kind   TEXT    NOT NULL
                  CONSTRAINT answers_answerer_kind_enum CHECK (answerer_kind IN ('user', 'parent_run', 'caller')),
  -- The run that answered. Set only when parent_run.
  answerer_run_id TEXT    REFERENCES runs (id),
  PRIMARY KEY (run_id, question_id),
  FOREIGN KEY (run_id, question_id) REFERENCES questions (run_id, id),
  CONSTRAINT answers_answerer_run_id_iff_parent_run CHECK ((answerer_run_id IS NOT NULL) = (answerer_kind = 'parent_run'))
) STRICT;
CREATE TABLE user_needs (
  -- What the user must still do by hand for a run: an admin console, a secret value, infrastructure.
  -- A need marked done leaves the table; the run's log keeps both events.

  -- The run.
  run_id TEXT    NOT NULL REFERENCES runs (id),
  -- The seq of the user_needed event.
  id     INTEGER NOT NULL,
  -- What the user must do, one line.
  text   TEXT    NOT NULL,
  -- Where to do it: an absolute URI. Optional: a need may name none.
  url    TEXT,
  PRIMARY KEY (run_id, id),
  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq)
) STRICT;
CREATE TABLE user_need_blocks (
  -- A task an open user need holds up.

  -- The run.
  run_id       TEXT    NOT NULL REFERENCES runs (id),
  -- The need: user_needs.id.
  user_need_id INTEGER NOT NULL,
  -- The breakdown of the task.
  breakdown_id INTEGER NOT NULL,
  -- The task the need holds up.
  task_id      TEXT    NOT NULL,
  PRIMARY KEY (run_id, user_need_id, breakdown_id, task_id),
  FOREIGN KEY (run_id, user_need_id) REFERENCES user_needs (run_id, id),
  FOREIGN KEY (run_id, breakdown_id, task_id) REFERENCES tasks (run_id, breakdown_id, id)
) STRICT;
