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
# It checks that a clone survives the target resetting its connections
# mid-clone. A background killer terminates pgcopydb's target backends
# throughout the clone; the clone must still finish successfully and land
# identical data, confirming the reconnect-and-replay paths (table COPY,
# CREATE INDEX, sequences, blobs) recover transparently instead of being
# torn down by --fail-fast.

# make sure source and target databases are ready
pgcopydb ping

# build the source dataset: tables + indexes + a sequence + large objects, so
# that the clone exercises every reconnect-and-replay path at once
psql -d "${PGCOPYDB_SOURCE_PGURI}" -1 -f /usr/src/pgcopydb/import.sql

# record the source state we expect to see on the target after the clone
SQL="select
       (select count(*) from t1) as t1,
       (select count(*) from t2) as t2,
       (select count(*) from t3) as t3,
       (select count(*) from t4) as t4,
       (select last_value from standalone_seq) as seq,
       (select count(*) from pg_largeobject_metadata) as blobs;"

psql -AXqt -d "${PGCOPYDB_SOURCE_PGURI}" -c "${SQL}" > /tmp/source.state

# start the backend killer in the background for the whole clone; it stops
# when we create the sentinel file
stopfile=/tmp/killer.stop
rm -f "${stopfile}"
bash /usr/src/pgcopydb/killer.sh "${stopfile}" &
killer_pid=$!

# Run the clone while the killer resets target connections underneath it.
# --restart so a re-run inside the same container starts clean; the clone is
# expected to exit 0 despite the resets. --max-replay-attempts enables the
# reconnect-and-replay paths (off by default); without it the first reset would
# fail the clone. Capture the exit code rather than letting `set -e` abort, so
# the killer is always stopped and the failure is reported explicitly below.
clone_rc=0
pgcopydb clone --notice --restart \
         --max-replay-attempts 5 \
         --table-jobs "${PGCOPYDB_TABLE_JOBS}" \
         --index-jobs "${PGCOPYDB_INDEX_JOBS}" \
         --source "${PGCOPYDB_SOURCE_PGURI}" \
         --target "${PGCOPYDB_TARGET_PGURI}" || clone_rc=$?

# stop the killer
touch "${stopfile}"
wait "${killer_pid}" || true

# the clone must have succeeded despite the resets
test "${clone_rc}" = "0"

# the target data must match the source exactly
psql -AXqt -d "${PGCOPYDB_TARGET_PGURI}" -c "${SQL}" > /tmp/target.state

diff /tmp/source.state /tmp/target.state

pgcopydb list progress --summary || true

echo "target-connection-drop: clone survived the backend resets and data matches"
