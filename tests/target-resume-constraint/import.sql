-- Dataset for the target-resume-constraint test.
--
-- A few small tables, each with a primary key constraint. The primary keys are
-- what matters here: the test drives pgcopydb into the state a process killed
-- mid-constraint leaves behind (constraint created on the target, but its
-- summary never marked done) and asserts that a fresh --resume process adopts
-- the unfinished summary instead of re-adding the already-built primary key.
create table t1 (id bigserial primary key, payload text not null);
create table t2 (id bigserial primary key, payload text not null);
create table t3 (id bigserial primary key, payload text not null);

insert into t1 (payload) select md5(g::text) from generate_series(1, 1000) g;
insert into t2 (payload) select md5(g::text) from generate_series(1, 1000) g;
insert into t3 (payload) select md5(g::text) from generate_series(1, 1000) g;
