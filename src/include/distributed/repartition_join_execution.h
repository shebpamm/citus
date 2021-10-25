/*-------------------------------------------------------------------------
 *
 * repartition_join_execution.h
 *	  Execution logic for repartition queries.
 *
 * Copyright (c) Citus Data, Inc.
 *-------------------------------------------------------------------------
 */

#ifndef REPARTITION_JOIN_EXECUTION_H
#define REPARTITION_JOIN_EXECUTION_H

#include "nodes/pg_list.h"

extern List * ExecuteDependentTasks(List *taskList, Job *topLevelJob);
extern void EnsureCompatibleLocalExecutionState(List *taskList);


#endif /* REPARTITION_JOIN_EXECUTION_H */
