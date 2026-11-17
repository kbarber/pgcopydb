# target-connection-drop

Checks that a `pgcopydb clone` survives the target database resetting its
connections mid-clone, recovering transparently instead of aborting.

A background killer (`killer.sh`) repeatedly runs `pg_terminate_backend()`
against every `pgcopydb%` backend on the **target** while a full
`pgcopydb clone` is running. The dataset (`import.sql`) is sized and shaped so
the clone exercises every reconnect-and-replay path at once:

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
