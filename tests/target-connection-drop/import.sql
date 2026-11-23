-- Dataset for the target-connection-drop test.
--
-- It deliberately exercises every clone code path that this test protects
-- against a target-side connection reset:
--
--   - table COPY (already resilient via the table-data outer retry loop)
--   - CREATE INDEX workers (indexes.c reconnect-and-replay)
--   - setval() of sequences (sequences.c transaction restart)
--   - large object copy (blobs.c batch restart)
--
-- The volume is sized so a full clone stays busy for several seconds, giving
-- the backend killer running alongside it a wide window to reset pgcopydb's
-- target connections mid-flight.

-- A handful of tables, each with its own sequence-backed identity column and a
-- couple of secondary indexes, so the CREATE INDEX and setval paths both get a
-- meaningful amount of work.
create table t1 (id bigserial primary key, payload text not null, n int not null);
create table t2 (id bigserial primary key, payload text not null, n int not null);
create table t3 (id bigserial primary key, payload text not null, n int not null);
create table t4 (id bigserial primary key, payload text not null, n int not null);

insert into t1 (payload, n)
     select repeat(md5(g::text), 8), g % 1000
       from generate_series(1, 120000) g;

insert into t2 (payload, n)
     select repeat(md5(g::text), 8), g % 1000
       from generate_series(1, 120000) g;

insert into t3 (payload, n)
     select repeat(md5(g::text), 8), g % 1000
       from generate_series(1, 120000) g;

insert into t4 (payload, n)
     select repeat(md5(g::text), 8), g % 1000
       from generate_series(1, 120000) g;

create index t1_n_idx on t1 (n);
create index t1_payload_idx on t1 (payload);
create index t2_n_idx on t2 (n);
create index t2_payload_idx on t2 (payload);
create index t3_n_idx on t3 (n);
create index t3_payload_idx on t3 (payload);
create index t4_n_idx on t4 (n);
create index t4_payload_idx on t4 (payload);

-- A standalone sequence advanced to a non-trivial value, so the setval path
-- has a value to carry across that we can assert on afterwards.
create sequence standalone_seq;
select setval('standalone_seq', 987654);

-- A spread of large objects so the blob worker runs several batches.
do $$
declare
  i int;
  loid oid;
begin
  for i in 1..400 loop
    loid := lo_create(0);
    perform lo_put(loid, 0, decode(repeat(md5(i::text), 64), 'escape'));
  end loop;
end
$$;
