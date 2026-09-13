-- ============================================================================
-- FILE: src/02_unindexed_baseline_audit.sql
-- ENTERPRISE PRACTICE: Elsamag IT Solutions
-- AUTHOR & LEAD TECHNICAL CONSULTANT: Samuel Chinwendu Agu
-- REPOSITORY: https://github.com/Elsamag/postgres-ecommerce-indexing-audit
-- DIALECT: PostgreSQL 15 / 16 Standard SQL
-- OBJECTIVE: Diagnostic baseline audit capturing unindexed sequential scans,
--            disk-spilling sorting bottlenecks, shared buffer churn, and
--            predicate selectivity across 3.85M fulfillment records.
-- ============================================================================

\timing on
SET statement_timeout = '300s';

-- ----------------------------------------------------------------------------
-- SECTION 1: EXTENSION ACTIVATION & STATISTICAL PRE-FLIGHT
-- Architectural Intent: Verify runtime observability extensions and establish
-- an isolated measurement baseline for shared buffer block consumption.
-- ----------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_buffercache;

-- Reset query stats cache to isolate baseline audit metrics (superuser/pg_read_all_stats)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_proc WHERE proname = 'pg_stat_statements_reset'
    ) THEN
        PERFORM pg_stat_statements_reset();
    END IF;
EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE NOTICE 'Skipping pg_stat_statements_reset: insufficient privilege.';
END $$;

-- ----------------------------------------------------------------------------
-- SECTION 2: HEAP SCALE, PHYSICAL FOOTPRINT & INDEX ABSENCE AUDIT
-- Architectural Intent: Document physical storage dimensions and prove the total
-- absence of existing indexes supporting the fulfillment dispatch filter.
-- ----------------------------------------------------------------------------

SELECT
    c.relname AS table_name,
    pg_size_pretty(pg_relation_size(c.oid)) AS heap_size,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    c.reltuples::BIGINT AS estimated_row_count,
    c.relpages AS total_heap_pages
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname = 'orders';

SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE tablename = 'orders'
ORDER BY indexname;

-- ----------------------------------------------------------------------------
-- SECTION 3: PREDICATE SELECTIVITY & DATA SKEW DIAGNOSTIC
-- Architectural Intent: Quantify predicate selectivity. If active queue rows
-- represent < 1% of the table heap, a sequential scan reading 100% of pages
-- is an acute systemic inefficiency solvable via targeted B-Tree partial indexing.
-- ----------------------------------------------------------------------------

SELECT
    fulfillment_status,
    COUNT(*) AS row_count,
    ROUND(
        (COUNT(*) * 100.0 / SUM(COUNT(*)) OVER ()),
        3
    ) AS selectivity_percentage,
    CASE 
        WHEN fulfillment_status = 'AWAITING_DISPATCH' 
        THEN 'TARGET: High-frequency polling queue (Ideal Partial Index Target)'
        ELSE 'HISTORICAL: Completed terminal states'
    END AS operational_role
FROM orders
GROUP BY fulfillment_status
ORDER BY row_count ASC;

-- ----------------------------------------------------------------------------
-- SECTION 4: UNINDEXED POLLING QUERY EXECUTION PLAN TRACE
-- Architectural Intent: Run EXPLAIN (ANALYZE, BUFFERS) on the unindexed queue.
-- Identifies Parallel Seq Scan, shared buffer cache misses, and external disk sort.
-- ----------------------------------------------------------------------------

EXPLAIN (ANALYZE, BUFFERS, SETTINGS, VERBOSE)
SELECT 
    order_id,
    customer_id,
    total_amount,
    warehouse_code,
    order_timestamp
FROM orders
WHERE fulfillment_status = 'AWAITING_DISPATCH'
ORDER BY order_timestamp ASC
LIMIT 100;

-- ----------------------------------------------------------------------------
-- SECTION 5: SHARED BUFFER CACHE RESIDENCY & DIRTY PAGE FOOTPRINT
-- Architectural Intent: Inspect PostgreSQL shared_buffers memory space to
-- measure the volume of 8KB buffer blocks occupied by the orders table heap.
-- ----------------------------------------------------------------------------

SELECT
    c.relname AS relation_name,
    COUNT(*) AS buffered_blocks,
    pg_size_pretty(COUNT(*) * 8192) AS buffer_ram_footprint,
    ROUND(
        100.0 * COUNT(*) / (
            SELECT setting FROM pg_settings WHERE name = 'shared_buffers'
        )::NUMERIC, 
        2
    ) AS percent_of_shared_buffers,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE b.isdirty) / COUNT(*),
        2
    ) AS percent_dirty_pages
FROM pg_buffercache b
JOIN pg_class c ON b.relfilenode = pg_relation_filenode(c.oid)
JOIN pg_database d ON (b.reldatabase = d.oid AND d.datname = current_database())
WHERE c.relname = 'orders'
GROUP BY c.relname;

-- ----------------------------------------------------------------------------
-- SECTION 6: WORKLOAD SEQUENTIAL SCAN VS INDEX SCAN ACCUMULATOR
-- Architectural Intent: Extract cumulative engine counters from pg_stat_user_tables
-- to establish baseline sequential scans and tuples scanned prior to indexing.
-- ----------------------------------------------------------------------------

SELECT
    relname AS table_name,
    seq_scan AS sequential_scans_total,
    seq_tup_read AS tuples_read_via_seq_scan,
    idx_scan AS index_scans_total,
    idx_tup_fetch AS tuples_fetched_via_index,
    n_tup_ins AS total_inserts,
    n_tup_upd AS total_updates,
    n_live_tup AS active_tuples,
    n_dead_tup AS dead_bloat_tuples
FROM pg_stat_user_tables
WHERE relname = 'orders';

-- ----------------------------------------------------------------------------
-- SECTION 7: PG_STAT_STATEMENTS LATENCY & BUFFER DRIFT BASELINE
-- Architectural Intent: Record mean execution time and buffer read spikes for
-- the specific dispatch query signature to serve as pre-refactor benchmark proof.
-- ----------------------------------------------------------------------------

SELECT
    queryid,
    calls,
    ROUND(total_exec_time::NUMERIC, 2) AS total_exec_time_ms,
    ROUND(mean_exec_time::NUMERIC, 2) AS mean_exec_time_ms,
    ROUND(max_exec_time::NUMERIC, 2) AS max_exec_time_ms,
    shared_blks_hit,
    shared_blks_read,
    ROUND(
        100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0),
        2
    ) AS buffer_cache_hit_ratio,
    SUBSTRING(query, 1, 120) AS query_signature
FROM pg_stat_statements
WHERE query ILIKE '%fulfillment_status = %AWAITING_DISPATCH%'
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY mean_exec_time DESC
LIMIT 5;
