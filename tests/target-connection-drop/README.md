# target-connection-drop

Reproduces the production "dropped connection" clone failure and proves the
reconnect-and-replay fix.

In production, test forks clone into a single, undersized, burstable target
(a `db.t4g.medium` Aurora instance). Once the clone exhausts the target's CPU
credits and memory, the target resets pgcopydb's connections mid-clone. The
old `--fail-fast` behaviour turned any one of those resets into a hard abort
(`connection pointer is NULL`, `SIGTERM`, exit 12).

This test recreates that condition deterministically: a background killer
(`killer.sh`) repeatedly runs `pg_terminate_backend()` against every
`pgcopydb%` backend on the **target** while a full `pgcopydb clone` is running.
The dataset (`import.sql`) is sized and shaped so the clone exercises every
reconnect-and-replay path at once:

- table COPY (already resilient via the table-data outer retry loop)
- CREATE INDEX workers (`indexes.c`)
- `setval()` of sequences (`sequences.c`)
- large object copy (`blobs.c`)
- the central single-statement path (`pgsql_execute_with_params`)

The clone must still exit `0` and land data identical to the source (row
counts per table, the standalone sequence's value, and the large object count
all match), confirming the resets were recovered transparently rather than
aborting the clone.

Run it with:

```
make -C tests target-connection-drop
```
