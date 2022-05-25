CREATE SCHEMA citus_split_shard_by_split_points;
SET search_path TO citus_split_shard_by_split_points;
SET citus.shard_replication_factor TO 1;
SET citus.shard_count TO 1;
SET citus.next_shard_id TO 1;

-- Add two additional nodes to cluster.
SELECT 1 FROM citus_add_node('localhost', :worker_1_port);
SELECT 1 FROM citus_add_node('localhost', :worker_2_port);

SELECT nodeid AS worker_1_node FROM pg_dist_node WHERE nodeport=:worker_1_port \gset
SELECT nodeid AS worker_2_node FROM pg_dist_node WHERE nodeport=:worker_2_port \gset

-- Create distributed table (non co-located)
CREATE TABLE table_to_split (id bigserial PRIMARY KEY, value char);
SELECT create_distributed_table('table_to_split','id');

-- slotName_table is used to persist replication slot name.
-- It is only used for testing as the worker2 needs to create subscription over the same replication slot.
CREATE TABLE slotName_table (name text, nodeId int, id int primary key);
SELECT create_distributed_table('slotName_table','id');

-- targetNode1, targetNode2 are the locations where childShard1 and childShard2 are placed respectively
CREATE OR REPLACE FUNCTION SplitShardReplicationSetup(targetNode1 integer, targetNode2 integer) RETURNS text AS $$
DECLARE
    memoryId bigint := 0;
    memoryIdText text;
begin
	SELECT * into memoryId from split_shard_replication_setup(ARRAY[ARRAY[1,2,-2147483648,-1, targetNode1], ARRAY[1,3,0,2147483647,targetNode2]]);
    SELECT FORMAT('%s', memoryId) into memoryIdText;
    return memoryIdText;
end
$$ LANGUAGE plpgsql;

-- Create replication slots for targetNode1 and targetNode2
CREATE OR REPLACE FUNCTION CreateReplicationSlot(targetNode1 integer, targetNode2 integer) RETURNS text AS $$
DECLARE
    targetOneSlotName text;
    targetTwoSlotName text;
    sharedMemoryId text;
    derivedSlotName text;
begin

    SELECT * into sharedMemoryId from SplitShardReplicationSetup(targetNode1, targetNode2);
    SELECT FORMAT('%s_%s', targetNode1, sharedMemoryId) into derivedSlotName;
    SELECT slot_name into targetOneSlotName from pg_create_logical_replication_slot(derivedSlotName, 'logical_decoding_plugin');

    -- if new child shards are placed on different nodes, create one more replication slot
    if (targetNode1 != targetNode2) then
        SELECT FORMAT('%s_%s', targetNode2, sharedMemoryId) into derivedSlotName;
        SELECT slot_name into targetTwoSlotName from pg_create_logical_replication_slot(derivedSlotName, 'logical_decoding_plugin');
        INSERT INTO slotName_table values(targetTwoSlotName, targetNode2, 1);
    end if;

    INSERT INTO slotName_table values(targetOneSlotName, targetNode1, 2);
    return targetOneSlotName;
end
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION CreateSubscription(targetNodeId integer, subscriptionName text) RETURNS text AS $$
DECLARE
    replicationSlotName text;
    nodeportLocal int;
    subname text;
begin
    SELECT name into replicationSlotName from slotName_table where nodeId = targetNodeId;
    EXECUTE FORMAT($sub$create subscription %s connection 'host=localhost port=57637 user=postgres dbname=regression' publication PUB1 with(create_slot=false, enabled=true, slot_name='%s', copy_data=false)$sub$, subscriptionName, replicationSlotName);
    return 'a';
end
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION DropSubscription(subscriptionName text) RETURNS text AS $$
DECLARE
begin
    EXECUTE FORMAT('DROP SUBSCRIPTION %s', subscriptionName);
    return subscriptionName;
end
$$ LANGUAGE plpgsql;

-- Test scenario one starts from here
-- 1. table_to_split is a citus distributed table
-- 2. Shard table_to_split_1 is located on worker1.
-- 3. table_to_split_1 is split into table_to_split_2 and table_to_split_3.
--    table_to_split_2/3 are located on worker2
-- 4. execute UDF split_shard_replication_setup on worker1 with below
--    params:
--    split_shard_replication_setup
--        (
--          ARRAY[
--                ARRAY[1 /*source shardId */, 2 /* new shardId */,-2147483648 /* minHashValue */, -1 /* maxHasValue */ , 18 /* nodeId where new shard is placed */ ], 
--                ARRAY[1, 3 , 0 , 2147483647, 18 ]
--               ]
--         );
-- 5. Create Replication slot with 'logical_decoding_plugin'
-- 6. Setup Pub/Sub
-- 7. Insert into table_to_split_1 at source worker1
-- 8. Expect the results in either table_to_split_2 or table_to_split_2 at worker2

\c - - - :worker_2_port
SET search_path TO citus_split_shard_by_split_points;
CREATE TABLE table_to_split_1(id bigserial PRIMARY KEY, value char);
CREATE TABLE table_to_split_2(id bigserial PRIMARY KEY, value char);
CREATE TABLE table_to_split_3(id bigserial PRIMARY KEY, value char);

-- Create dummy shard tables(table_to_split_2/3) at worker1
-- This is needed for Pub/Sub framework to work.
\c - - - :worker_1_port
SET search_path TO citus_split_shard_by_split_points;
BEGIN;
    CREATE TABLE table_to_split_2(id bigserial PRIMARY KEY, value char);
    CREATE TABLE table_to_split_3(id bigserial PRIMARY KEY, value char);
COMMIT;

-- Create publication at worker1
BEGIN;
    CREATE PUBLICATION PUB1 for table table_to_split_1, table_to_split_2, table_to_split_3;
COMMIT;

-- Create replication slot and setup shard split information at worker1
BEGIN;
select 1 from CreateReplicationSlot(:worker_2_node, :worker_2_node);
COMMIT;

\c - - - :worker_2_port
SET search_path TO citus_split_shard_by_split_points;

-- Create subscription at worker2 with copy_data to 'false' and derived replication slot name
BEGIN;
SELECT 1 from CreateSubscription(:worker_2_node, 'SUB1');
COMMIT;

-- No data is present at this moment in all the below tables at worker2
SELECT * from table_to_split_1;
SELECT * from table_to_split_2;
SELECT * from table_to_split_3;
select pg_sleep(10);

-- Insert data in table_to_split_1 at worker1 
\c - - - :worker_1_port
SET search_path TO citus_split_shard_by_split_points;
INSERT into table_to_split_1 values(100, 'a');
INSERT into table_to_split_1 values(400, 'a');
INSERT into table_to_split_1 values(500, 'a');
SELECT * from table_to_split_1;
SELECT * from table_to_split_2;
SELECT * from table_to_split_3;
select pg_sleep(10);

-- Expect data to be present in shard 2 and shard 3 based on the hash value.
\c - - - :worker_2_port
select pg_sleep(10);
SET search_path TO citus_split_shard_by_split_points;
SELECT * from table_to_split_1; -- should alwasy have zero rows
SELECT * from table_to_split_2;
SELECT * from table_to_split_3;

-- Delete data from table_to_split_1 from worker1
\c - - - :worker_1_port
SET search_path TO citus_split_shard_by_split_points;
DELETE FROM table_to_split_1;
SELECT pg_sleep(10);

-- Child shard rows should be deleted
\c - - - :worker_2_port
SET search_path TO citus_split_shard_by_split_points;
SELECT * FROM table_to_split_1;
SELECT * FROM table_to_split_2;
SELECT * FROM table_to_split_3;

 -- drop publication from worker1
\c - - - :worker_1_port
SET search_path TO citus_split_shard_by_split_points;
drop PUBLICATION PUB1;
DELETE FROM slotName_table;

\c - - - :worker_2_port
SET search_path TO citus_split_shard_by_split_points;
SET client_min_messages TO WARNING;
DROP SUBSCRIPTION SUB1;
DELETE FROM slotName_table;

-- Test scenario two starts from here
-- 1. table_to_split_1 is split into table_to_split_2 and table_to_split_3. table_to_split_1 is
--    located on worker1.
--    table_to_split_2 is located on worker1 and table_to_split_3 is located on worker2

\c - - - :worker_1_port
SET search_path TO citus_split_shard_by_split_points;

-- Create publication at worker1
BEGIN;
    CREATE PUBLICATION PUB1 for table table_to_split_1, table_to_split_2, table_to_split_3;
COMMIT;

-- Create replication slot and setup shard split information at worker1
-- table_to_split2 is located on Worker1 and table_to_split_3 is located on worker2
BEGIN;
select 1 from CreateReplicationSlot(:worker_1_node, :worker_2_node);
COMMIT;
SELECT pg_sleep(10);

-- Create subscription at worker1 with copy_data to 'false' and derived replication slot name
BEGIN;
SELECT 1 from CreateSubscription(:worker_1_node, 'SUB1');
COMMIT;

\c - - - :worker_2_port
SET search_path TO citus_split_shard_by_split_points;

-- Create subscription at worker2 with copy_data to 'false' and derived replication slot name
BEGIN;
SELECT 1 from CreateSubscription(:worker_2_node, 'SUB2');
COMMIT;

-- No data is present at this moment in all the below tables at worker2
SELECT * from table_to_split_1;
SELECT * from table_to_split_2;
SELECT * from table_to_split_3;
select pg_sleep(10);

-- Insert data in table_to_split_1 at worker1
\c - - - :worker_1_port
SET search_path TO citus_split_shard_by_split_points;
INSERT into table_to_split_1 values(100, 'a');
INSERT into table_to_split_1 values(400, 'a');
INSERT into table_to_split_1 values(500, 'a');
select pg_sleep(10);

-- expect data to present in table_to_split_2 on worker1
SELECT * from table_to_split_1;
SELECT * from table_to_split_2; 
SELECT * from table_to_split_3;
select pg_sleep(10);

-- Expect data to be present in table_to_split3 on worker2
\c - - - :worker_2_port
select pg_sleep(10);
SET search_path TO citus_split_shard_by_split_points;
SELECT * from table_to_split_1;
SELECT * from table_to_split_2; 
SELECT * from table_to_split_3;

-- delete all from table_to_split_1
\c - - - :worker_1_port
SET search_path TO citus_split_shard_by_split_points;
DELETE FROM table_to_split_1;
SELECT pg_sleep(5);

-- rows from table_to_split_2 should be deleted
SELECT * from table_to_split_2;

-- rows from table_to_split_3 should be deleted
\c - - - :worker_2_port
SET search_path TO citus_split_shard_by_split_points;
SELECT * from table_to_split_3;