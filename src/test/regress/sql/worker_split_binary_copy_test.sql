CREATE SCHEMA worker_split_binary_copy_test;
SET search_path TO worker_split_binary_copy_test;
SET citus.shard_count TO 1;
SET citus.shard_replication_factor TO 1;
SET citus.next_shard_id TO 81060000;

-- BEGIN: Create distributed table and insert data.
CREATE TABLE worker_split_binary_copy_test.shard_to_split_copy (id bigserial PRIMARY KEY, value char);
SELECT create_distributed_table('shard_to_split_copy','id');
INSERT INTO worker_split_binary_copy_test.shard_to_split_copy (id, value) (SELECT g.id, 'c' FROM generate_series(1, 100) AS g(id));
-- END: Create distributed table and insert data.

-- BEGIN: Switch to Worker1, Create target shards in worker for local 2-way split copy.
\c - - - :worker_1_port
CREATE TABLE worker_split_binary_copy_test.shard_to_split_copy_81060015 (id bigserial PRIMARY KEY, value char);
CREATE TABLE worker_split_binary_copy_test.shard_to_split_copy_81060016 (id bigserial PRIMARY KEY, value char);
-- End: Switch to Worker1, Create target shards in worker for local 2-way split copy.

-- BEGIN: Switch to Worker2, Create target shards in worker for remote 2-way split copy.
\c - - - :worker_2_port
CREATE TABLE worker_split_binary_copy_test.shard_to_split_copy_81060015 (id bigserial PRIMARY KEY, value char);
CREATE TABLE worker_split_binary_copy_test.shard_to_split_copy_81060016 (id bigserial PRIMARY KEY, value char);
-- End: Switch to Worker2, Create target shards in worker for remote 2-way split copy.

-- BEGIN: List row count for source shard and targets shard in Worker1.
\c - - - :worker_1_port
SELECT COUNT(*) FROM worker_split_binary_copy_test.shard_to_split_copy_81060000;
SELECT COUNT(*) FROM worker_split_binary_copy_test.shard_to_split_copy_81060015;
SELECT COUNT(*) FROM worker_split_binary_copy_test.shard_to_split_copy_81060016;
-- END: List row count for source shard and targets shard in Worker1.

-- BEGIN: List row count for target shard in Worker2.
\c - - - :worker_2_port
SELECT COUNT(*) FROM worker_split_binary_copy_test.shard_to_split_copy_81060015;
SELECT COUNT(*) FROM worker_split_binary_copy_test.shard_to_split_copy_81060016;
-- END: List row count for targets shard in Worker2.

-- BEGIN: Set worker_1_node and worker_2_node
\c - - - :worker_1_port
SELECT nodeid AS worker_1_node FROM pg_dist_node WHERE nodeport=:worker_1_port \gset
SELECT nodeid AS worker_2_node FROM pg_dist_node WHERE nodeport=:worker_2_port \gset
-- END: Set worker_1_node and worker_2_node

-- BEGIN: Trigger 2-way local shard split copy.
SELECT * from worker_split_copy(
    81060000, -- source shard id to copy
    ARRAY[
         -- split copy info for split children 1
        ROW(81060015, -- destination shard id
             -2147483648, -- split range begin
            1073741823, --split range end
            :worker_1_node)::citus.split_copy_info,
        -- split copy info for split children 2
        ROW(81060016,  --destination shard id
            1073741824, --split range begin
            2147483647, --split range end
            :worker_1_node)::citus.split_copy_info
        ]
    );
-- END: Trigger 2-way local shard split copy.

-- BEGIN: Trigger 2-way remote shard split copy.
SELECT * from worker_split_copy(
    81060000, -- source shard id to copy
    ARRAY[
         -- split copy info for split children 1
        ROW(81060015, -- destination shard id
             -2147483648, -- split range begin
            1073741823, --split range end
            :worker_2_node)::citus.split_copy_info,
        -- split copy info for split children 2
        ROW(81060016,  --destination shard id
            1073741824, --split range begin
            2147483647, --split range end
            :worker_2_node)::citus.split_copy_info
        ]
    );
-- END: Trigger 2-way remote shard split copy.

-- BEGIN: List updated row count for local targets shard.
SELECT COUNT(*) FROM worker_split_binary_copy_test.shard_to_split_copy_81060015;
SELECT COUNT(*) FROM worker_split_binary_copy_test.shard_to_split_copy_81060016;
-- END: List updated row count for local targets shard.

-- BEGIN: List updated row count for remote targets shard.
\c - - - :worker_2_port
SELECT COUNT(*) FROM worker_split_binary_copy_test.shard_to_split_copy_81060015;
SELECT COUNT(*) FROM worker_split_binary_copy_test.shard_to_split_copy_81060016;
-- END: List updated row count for remote targets shard.

-- BEGIN: CLEANUP.
\c - - - :master_port
SET client_min_messages TO WARNING;
DROP SCHEMA citus_split_shard_by_split_points_local CASCADE;
-- END: CLEANUP.