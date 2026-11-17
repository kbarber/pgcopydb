#! /bin/bash
#
# Repeatedly terminate pgcopydb's backends on the TARGET database, simulating
# the target dropping connections out from under a running clone.
#
# This script runs in the background for the whole clone and keeps killing
# pgcopydb target backends until it is told to stop (the main script creates
# the sentinel file named by $1). Every reset here must be transparently
# recovered by pgcopydb's reconnect-and-replay paths for the clone to succeed.

set -u

stopfile="$1"

# pg_terminate_backend every connection whose application_name marks it as one
# of pgcopydb's (see pgsql.c: PGAPPNAME is always "pgcopydb[<pid>] ..."),
# except our own psql connection running this very query.
kill_sql="select count(pg_terminate_backend(pid))
            from pg_stat_activity
           where application_name like 'pgcopydb%'
             and pid <> pg_backend_pid();"

killed=0

while [ ! -f "${stopfile}" ]
do
    n=$(psql -AXqt -d "${PGCOPYDB_TARGET_PGURI}" -c "${kill_sql}" 2>/dev/null)

    if [ -n "${n}" ] && [ "${n}" -gt 0 ] 2>/dev/null
    then
        killed=$((killed + n))
        echo "killer: terminated ${n} pgcopydb target backend(s) (total ${killed})"
    fi

    # Short enough to land several resets inside a single clone, long enough
    # to let the clone make forward progress (and finish) between resets.
    sleep 0.3
done

echo "killer: stopping, terminated ${killed} pgcopydb target backend(s) in total"
