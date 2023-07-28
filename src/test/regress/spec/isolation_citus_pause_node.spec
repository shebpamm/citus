setup
{
	SET citus.shard_replication_factor to 1;

    CREATE TABLE company(id int primary key, name text);
	select create_distributed_table('company', 'id');

	create table employee(id int , name text, company_id int  );
	alter table employee add constraint employee_pkey primary key (id,company_id);

	select create_distributed_table('employee', 'company_id');

	insert into company values(1,'c1');
	insert into company values(2,'c2');
	insert into company values(3,'c3');

	insert into employee values(1,'e1',1);
	insert into employee values(2,'e2',1);
	insert into employee values(3,'e3',1);

	insert into employee values(4,'e4',2);
	insert into employee values(5,'e5',2);
	insert into employee values(6,'e6',2);

	insert into employee values(7,'e7',3);
	insert into employee values(8,'e8',3);
	insert into employee values(9,'e9',3);
	insert into employee values(10,'e10',3);


}

teardown
{
    DROP TABLE company,employee;
}

session "s1"

step "s1-begin"
{
    BEGIN;
	select * from pg_dist_node;
	SELECT get_shard_id_for_distribution_column('employee', 3);


}

step "s1-pause-node"
{
	SET client_min_messages = 'notice';
	DO $$
	DECLARE
		v_shard_id int;
		v_node_id int;
		v_node_name text;
		v_node_port int;
	BEGIN
			-- Get the shard id for the distribution column
		SELECT get_shard_id_for_distribution_column('employee', 3) into shard_id;

		--Get the node id for the shard id
		SELECT nodename,nodeport into v_node_name,v_node_port FROM citus_shards WHERE shard_id = v_shard_id limit 1;
		raise notice 'node name is %',v_node_name;
		raise notice 'node port is %',v_node_port;

		-- Get the node id for the shard id
		SELECT nodeid into v_node_id FROM pg_dist_node WHERE nodename = v_node_name and nodeport = v_node_port limit 1;
		raise notice 'node id is %',v_node_id;


		-- Pause the node
		SELECT pg_catalog.citus_pause_node(v_node_id);
	END;
	$$
	LANGUAGE plpgsql;
}

step "s1-end"
{
    COMMIT;
}

session "s2"


step "s2-begin"
{
	BEGIN;
}

step "s2-insert"
{
	-- Set statement_timeout for the session (in milliseconds)
	SET statement_timeout = 1000; -- 1 seconds
	SET client_min_messages = 'notice';

	-- Variable to track if the INSERT statement was successful
	DO $$
	DECLARE
		v_insert_successful BOOLEAN := FALSE;
	BEGIN

		-- Execute the INSERT statement
		insert into employee values(11,'e11',3);

		-- If we reach this point, the INSERT statement was successful
		v_insert_successful := TRUE;

		IF v_insert_successful THEN
			RAISE NOTICE 'INSERT statement completed successfully. This means that citus_pause_node could not get the lock.';
		END IF;


	-- You can add additional processing here if needed
	EXCEPTION
		WHEN query_canceled THEN
			-- The INSERT statement was canceled due to timeout
			RAISE NOTICE 'query_canceled exception raised. This means that citus_pause_node was able to get the lock.';
		WHEN OTHERS THEN
			-- Any other exception raised during the INSERT statement
			RAISE;
	END;

	$$
	LANGUAGE plpgsql;
}

step "s2-end"
{
	COMMIT;
}

permutation "s1-begin" "s1-pause-node" "s2-begin" "s2-insert" "s2-end" "s1-end"