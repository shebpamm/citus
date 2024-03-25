-- check that the nodes are all in read-only mode and rejecting write queries
ALTER SYSTEM SET citus.enable_ddl_propagation = 'true';
SELECT pg_reload_conf();

\c - - - :worker_1_port
ALTER SYSTEM SET citus.enable_ddl_propagation = 'true';
SELECT pg_reload_conf();

\c - - - :worker_2_port
ALTER SYSTEM SET citus.enable_ddl_propagation = 'true';
SELECT pg_reload_conf();

\c - - - :follower_master_port
ALTER SYSTEM SET citus.enable_ddl_propagation = 'true';
SELECT pg_reload_conf();

\c - - - :follower_worker_1_port
ALTER SYSTEM SET citus.enable_ddl_propagation = 'true';
SELECT pg_reload_conf();

\c - - - :follower_worker_2_port
ALTER SYSTEM SET citus.enable_ddl_propagation = 'true';
SELECT pg_reload_conf();


\c - - - :follower_master_port
CREATE TABLE tab (a int);
\c - - - :follower_worker_1_port
CREATE TABLE tab (a int);
\c - - - :follower_worker_2_port
CREATE TABLE tab (a int);
