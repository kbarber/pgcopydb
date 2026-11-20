# target-resume-constraint

Checks that a `pgcopydb clone --resume` recovers a constraint a worker was
building when it died, instead of re-adding an already-built primary key and
failing with `index "..._pkey" is already associated with a constraint`.

pgcopydb records the worker pid when it starts a constraint and only marks
completion for that same pid; a resumed run is a brand new process with a
different pid.

The bug is reachable only in one narrow window: the worker must die after the
`ALTER TABLE ... ADD CONSTRAINT` has committed on the target server but before
`summary_finish_constraint` writes the completion row to the SQLite catalog
(`copydb_create_constraints_hook`, between the `pgsql_execute` and the
`summary_finish_constraint` call). That gap is two near-adjacent operations -
sub-millisecond on a primary key over small tables - so an external kill rarely
lands inside it, and a kill on either side produces a *non-bug*: die before the
commit and the resume just rebuilds the constraint cleanly, die after the
completion write and there is no orphaned row at all. An external killer would
therefore mostly exercise those two healthy paths and flake, rather than
reproduce this failure.

The test instead reproduces the exact catalog residue a worker killed in that
window leaves behind (an unfinished summary row, `done_time = 0`, owned by a
dead pid `999999`, with the index/constraint/finalize timing sections cleared),
then runs a fresh `clone --resume`, which is what production does to recover an
interrupted clone. This hits the bug deterministically on every run.

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
