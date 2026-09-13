-- ============================================================================
-- FILE: src/04_buffer_cache_inspector.sql
-- ENTERPRISE PRACTICE: Elsamag IT Solutions
-- AUTHOR & LEAD TECHNICAL CONSULTANT: Samuel Chinwendu Agu
-- REPOSITORY: https://github.com/Elsamag/postgres-ecommerce-indexing-audit
-- PURPOSE: Low-level PostgreSQL shared_buffers memory cache diagnostic engine
--          inspecting buffer page residency, cache hit ratios, and clock-sweep
--          eviction risk across table heaps and partial B-Tree indexes.
-- DIALECT: PostgreSQL 15 / 16 Standard SQL
-- ============================================================================

-- Step 1: Initialize Low-Level Diagnostic Extensions
-- Architectural Intent: pg_buffercache allows real-time inspection of PostgreSQL's
-- internal shared_buffers pool without interrupting active read/write workloads.
CREATE EXTENSION IF NOT EXISTS pg_buffercache;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ============================================================================
-- QUERY 1: Global Buffer Cache Hit Ratio & I/O Efficiency
-- Architectural Intent: Quantify whether transaction traffic is hitting RAM (clean)
-- or spilling to physical disk reads. Healthy OLTP targets > 99.0% cache hits.
-- ============================================================================
SELECT 
    'Global Buffer Cache Hit Ratio' AS audit_metric,
    ROUND(
        100.0 * SUM(heap_blks_hit) / 
        NULLIF(SUM(heap_blks_hit + heap_blks_read), 0), 
        3
    ) AS cache_hit_percentage,
    SUM(heap_blks_read) AS total_disk_blocks_read,
    SUM(heap_blks_hit) AS total_ram_blocks_hit
FROM pg_statio_user_tables;

-- ============================================================================
-- QUERY 2: Target Relation Buffer Residency & Cache Footprint
-- Architectural Intent: Directly inspect how many 8 KB pages of the 3.85M row
-- 'orders' table heap vs. the partial index 'idx_orders_unfulfilled_dispatch_queue'
-- are resident in shared_buffers. Demonstrates how a 420 KB partial index remains
-- 100% memory-pinned, eliminating 1.44 GB table scans.
-- ============================================================================
WITH buffer_summary AS (
    SELECT 
        c.relname AS relation_name,
        CASE c.relkind 
            WHEN 'r' THEN 'Table Heap'
            WHEN 'i' THEN 'B-Tree Index'
            ELSE 'Other'
        END AS relation_type,
        pg_size_pretty(pg_relation_size(c.oid)) AS on_disk_size,
        pg_relation_size(c.oid) AS on_disk_bytes,
        COUNT(b.bufferid) AS buffered_pages,
        COUNT(b.bufferid) * 8192 AS buffered_bytes,
        COUNT(b.bufferid) FILTER (WHERE b.isdirty) AS dirty_pages,
        COUNT(b.bufferid) FILTER (WHERE NOT b.isdirty) AS clean_pages
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_buffercache b ON b.relfilenode = pg_relation_filenode(c.oid)
        AND b.reldatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
    WHERE n.nspname = 'public'
      AND c.relname IN (
          'orders',
          'idx_orders_unfulfilled_dispatch_queue',
          'idx_orders_status_timestamp_composite'
      )
    GROUP BY c.oid, c.relname, c.relkind
)
SELECT 
    relation_name,
    relation_type,
    on_disk_size,
    pg_size_pretty(buffered_bytes) AS memory_buffered_size,
    buffered_pages,
    ROUND(
        100.0 * buffered_bytes / NULLIF(on_disk_bytes, 0), 
        2
    ) AS percent_relation_in_ram,
    ROUND(
        100.0 * buffered_pages / (SELECT setting FROM pg_settings WHERE name = 'shared_buffers')::numeric, 
        3
    ) AS percent_shared_buffers_consumed,
    dirty_pages,
    clean_pages
FROM buffer_summary
ORDER BY on_disk_bytes DESC;

-- ============================================================================
-- QUERY 3: Clock-Sweep Usage Count & Cache Eviction Risk
-- Architectural Intent: PostgreSQL uses a clock-sweep algorithm (0 to 5) to 
-- determine buffer eviction priority. A usagecount of 5 indicates a hot, permanently
-- retained page. A usagecount <= 1 indicates high vulnerability to cache eviction.
-- ============================================================================
SELECT 
    c.relname AS relation_name,
    b.usagecount AS clock_sweep_usage_count,
    COUNT(b.bufferid) AS page_count,
    pg_size_pretty(COUNT(b.bufferid) * 8192) AS memory_size,
    ROUND(
        100.0 * COUNT(b.bufferid) / SUM(COUNT(b.bufferid)) OVER (PARTITION BY c.relname), 
        2
    ) AS percent_of_relation_buffer
FROM pg_class c
JOIN pg_buffercache b ON b.relfilenode = pg_relation_filenode(c.oid)
    AND b.reldatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
WHERE c.relname IN (
    'orders',
    'idx_orders_unfulfilled_dispatch_queue',
    'idx_orders_status_timestamp_composite'
)
GROUP BY c.relname, b.usagecount
ORDER BY c.relname, b.usagecount DESC;

-- ============================================================================
-- QUERY 4: Top 10 Memory Consuming Objects in Shared Buffers
-- Architectural Intent: Identify noisy-neighbor relations crowding out the working
-- memory set. Confirms that unindexed full table scans from other workloads are
-- not flushing critical fulfillment queues out of RAM.
-- ============================================================================
SELECT 
    n.nspname AS schema_name,
    c.relname AS relation_name,
    CASE c.relkind 
        WHEN 'r' THEN 'Table Heap'
        WHEN 'i' THEN 'Index'
        WHEN 't' THEN 'TOAST'
        ELSE 'Other'
    END AS object_type,
    COUNT(b.bufferid) AS buffered_pages,
    pg_size_pretty(COUNT(b.bufferid) * 8192) AS memory_footprint,
    ROUND(
        100.0 * COUNT(b.bufferid) / (SELECT setting FROM pg_settings WHERE name = 'shared_buffers')::numeric, 
        2
    ) AS shared_buffers_occupancy_pct
FROM pg_buffercache b
JOIN pg_class c ON b.relfilenode = pg_relation_filenode(c.oid)
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE b.reldatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
GROUP BY n.nspname, c.relname, c.relkind
ORDER BY buffered_pages DESC
LIMIT 10;
