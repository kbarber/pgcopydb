# target-resume-constraint

Checks that a `pgcopydb clone --resume` recovers a constraint a worker was
building when it died, instead of re-adding an already-built primary key and
failing with `index "..._pkey" is already associated with a constraint`.

pgcopydb records the worker pid when it starts a constraint and only marks
completion for that same pid; a resumed run is a brand new process with a
different pid. A real kill mid-constraint is racy (the `ALTER TABLE` takes
milliseconds), so the test reproduces the exact catalog residue a dead worker
leaves behind - an unfinished summary row (`done_time = 0`) owned by a dead pid
(`999999`), with the index/constraint/finalize timing sections cleared - then
runs a fresh `clone --resume`, which is what production does to recover an
interrupted clone.

The resumed run must take ownership of the orphaned summary row, record its
completion, and skip the already-built primary keys in post-data instead of
re-adding them.

A second scenario covers `clone --restart --drop-if-exists` against a target
that already holds the tables and their primary keys: the `DROP TABLE ...
CASCADE` also drops the primary keys after the target catalog was cached, so
the constraint build must re-query the live target rather than trust the stale
cache and silently leave the tables without their primary keys.

Run it with:

```
make -C tests target-resume-constraint
```
