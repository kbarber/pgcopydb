#! /bin/bash

set -x
set -e

# This script expects the following environment variables to be set:
#
#  - PGCOPYDB_SOURCE_PGURI
#  - PGCOPYDB_TARGET_PGURI
#  - PGCOPYDB_TABLE_JOBS
#  - PGCOPYDB_INDEX_JOBS
#
# It checks that a clone --resume run adopts an unfinished constraint summary
# left behind by a process that died mid-constraint. pgcopydb records the worker
# pid when it starts a constraint and only marks completion for that same pid; a
# resumed run is a brand new process with a different pid. If the resumed run
# does not take ownership of the orphaned summary row, completion is never
# recorded, and the post-data restore step re-adds the already-built primary key
# and fails with "multiple primary keys".
#
# A real kill mid-constraint is racy (the ALTER TABLE takes milliseconds), so we
# reproduce the exact catalog residue a dead worker leaves behind and then run a
# fresh clone --resume, which is what production does to recover an interrupted
# clone.

WORKDIR=${TMPDIR:-/tmp}/pgcopydb
CATALOG="${WORKDIR}/schema/source.db"

# make sure source and target databases are ready
pgcopydb ping

# build the source dataset: a few tables, each with a primary key constraint
psql -d "${PGCOPYDB_SOURCE_PGURI}" -1 -f /usr/src/pgcopydb/import.sql

# A clean, complete clone. This builds the primary keys on the target and
# records a finished summary row (done_time > 0) for each constraint.
pgcopydb clone --restart --notice \
         --table-jobs "${PGCOPYDB_TABLE_JOBS}" \
         --index-jobs "${PGCOPYDB_INDEX_JOBS}" \
         --source "${PGCOPYDB_SOURCE_PGURI}" \
         --target "${PGCOPYDB_TARGET_PGURI}"

# Simulate the residue a worker killed mid-constraint leaves behind.
#
# A constraint is built by the CREATE INDEX worker that finishes the last index
# of a table: it re-processes the index, then (because the index is done) builds
# the constraint. So a worker interrupted mid-constraint leaves both the index
# and the constraint summary unfinished and owned by its now-dead pid. We stage
# exactly that:
#
#   - the primary keys exist on the target (built by the clone above),
#   - every index and constraint summary row is unfinished (done_time = 0) and
#     owned by a dead worker pid (999999 can match no running process),
#   - the CREATE INDEX (6), ALTER TABLE (7), FINALIZE SCHEMA (11) and TOTAL (12)
#     timing sections are cleared so clone --resume re-runs the index/constraint
#     and post-data phases rather than treating the run as already complete.
#
# On resume the index worker reprocesses the index (CREATE INDEX IF NOT EXISTS
# is a no-op), reaches the constraint branch, sees the primary key already on the
# target so skips the ALTER, and calls summary_add_constraint followed by
# summary_finish_constraint. summary_finish_constraint filters on the live pid,
# so the add must claim ownership of the dead worker's row or completion is never
# recorded and post-data re-adds the primary key.
sqlite3 -init /dev/null "${CATALOG}" \
  "update summary set done_time_epoch = 0, pid = 999999 where conoid is not null"
sqlite3 -init /dev/null "${CATALOG}" \
  "update timings set done_time_epoch = null where id in (6, 7, 11, 12)"

# Prove the injected state is what we think it is: unfinished rows owned by the
# dead pid.
orphaned=$(sqlite3 -init /dev/null "${CATALOG}" \
  "select count(*) from summary where conoid is not null and done_time_epoch = 0 and pid = 999999")
test "${orphaned}" -gt 0

# Resume the clone with a fresh process (a different pid than 999999). It must
# take ownership of the orphaned summary rows, record their completion, and skip
# the already-built primary keys in post-data instead of re-adding them. Before
# the fix this fails with "multiple primary keys".
pgcopydb clone --resume --not-consistent --notice \
         --table-jobs "${PGCOPYDB_TABLE_JOBS}" \
         --index-jobs "${PGCOPYDB_INDEX_JOBS}" \
         --source "${PGCOPYDB_SOURCE_PGURI}" \
         --target "${PGCOPYDB_TARGET_PGURI}"

# Every constraint summary must now be finished and owned by a live pid, not the
# dead 999999 the resumed run inherited.
not_finished=$(sqlite3 -init /dev/null "${CATALOG}" \
  "select count(*) from summary where conoid is not null and done_time_epoch = 0")
test "${not_finished}" = "0"

stale_pid=$(sqlite3 -init /dev/null "${CATALOG}" \
  "select count(*) from summary where conoid is not null and pid = 999999")
test "${stale_pid}" = "0"

# source and target must match
pgcopydb compare schema
pgcopydb compare data

echo "target-resume-constraint: clone --resume adopted the orphaned constraint summary and post-data skipped the primary keys"

# Second scenario: clone --restart --drop-if-exists against a target that already
# holds the tables and their primary keys (left by the runs above).
#
# --drop-if-exists issues DROP TABLE ... CASCADE on the target, which also drops
# the primary keys, after the target catalog was already cached. The constraint
# build must not trust that stale cache and skip recreating the now-dropped
# primary keys, or the tables silently end up without them.
pgcopydb clone --restart --drop-if-exists --not-consistent --notice \
         --table-jobs "${PGCOPYDB_TABLE_JOBS}" \
         --index-jobs "${PGCOPYDB_INDEX_JOBS}" \
         --source "${PGCOPYDB_SOURCE_PGURI}" \
         --target "${PGCOPYDB_TARGET_PGURI}"

# Every table must still have its primary key on the target.
pkeys=$(psql -AtX -d "${PGCOPYDB_TARGET_PGURI}" -c \
  "select count(*) from pg_constraint where contype = 'p' and conrelid in ('public.t1'::regclass, 'public.t2'::regclass, 'public.t3'::regclass)")
test "${pkeys}" = "3"

pgcopydb compare schema
pgcopydb compare data

echo "target-resume-constraint: clone --restart --drop-if-exists rebuilt the dropped primary keys instead of trusting the stale target cache"
