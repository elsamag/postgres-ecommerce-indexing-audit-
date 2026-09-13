-- ============================================================================
-- FILE: src/01_schema_and_mock_data.sql
-- ENTERPRISE PRACTICE: Elsamag IT Solutions
-- AUTHOR & LEAD TECHNICAL CONSULTANT: Samuel Chinwendu Agu
-- TARGET REPOSITORY: https://github.com/Elsamag/postgres-ecommerce-indexing-audit
-- STACK: PostgreSQL 15 / 16 Standard SQL
-- OBJECTIVE: Provision the base e-commerce orders schema and populate 3,850,000
--            production-scale fulfillment records with realistic status skew,
--            timestamp distributions, and JSONB payloads for latency auditing.
-- ============================================================================

\timing on
SET client_min_messages = warning;

-- Step 1: Session Optimization for High-Throughput Bulk Ingestion
SET work_mem = '256MB';
SET maintenance_work_mem = '512MB';
SET synchronous_commit = off;

-- Step 2: Ensure Required Diagnostic Extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_buffercache";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";

-- Step 3: Base Schema Provisioning
DROP TABLE IF EXISTS orders CASCADE;

CREATE TABLE orders (
    order_id UUID NOT NULL,
    customer_id UUID NOT NULL,
    fulfillment_status VARCHAR(32) NOT NULL,
    order_timestamp TIMESTAMPTZ NOT NULL,
    shipping_priority VARCHAR(16) NOT NULL DEFAULT 'STANDARD',
    total_amount NUMERIC(10, 2) NOT NULL,
    warehouse_code VARCHAR(16) NOT NULL,
    metadata JSONB
);

-- Step 4: High-Velocity Parallel Synthetic Data Generation (3.85M Records)
-- Architectural Intent: Generates 3,850,000 rows utilizing set-based functions.
-- Status distribution mirrors live omnichannel logistics:
--   - 'AWAITING_DISPATCH' : ~0.48% (~18,500 rows, queued in the last 48 hours)
--   - 'SHIPPED'           : ~15.00% (~577,500 rows, past 14 days)
--   - 'DELIVERED'         : ~75.00% (~2,887,500 rows, past 365 days)
--   - 'RETURNED'          : ~7.00%  (~269,500 rows, past 365 days)
--   - 'CANCELLED'         : ~2.52%  (~97,000 rows, past 365 days)
INSERT INTO orders (
    order_id,
    customer_id,
    fulfillment_status,
    order_timestamp,
    shipping_priority,
    total_amount,
    warehouse_code,
    metadata
)
SELECT
    gen_random_uuid() AS order_id,
    gen_random_uuid() AS customer_id,
    status.val AS fulfillment_status,
    CASE 
        WHEN status.val = 'AWAITING_DISPATCH' THEN
            -- Active queue: Orders placed within the last 48 hours
            NOW() - (random() * INTERVAL '48 hours')
        WHEN status.val = 'SHIPPED' THEN
            -- In-transit queue: Orders placed between 2 and 14 days ago
            NOW() - INTERVAL '2 days' - (random() * INTERVAL '12 days')
        ELSE
            -- Historical records: Orders distributed across the past 365 days
            NOW() - INTERVAL '14 days' - (random() * INTERVAL '351 days')
    END AS order_timestamp,
    (ARRAY['STANDARD', 'EXPRESS', 'OVERNIGHT', 'SAME_DAY'])[1 + floor(random() * 4)::int] AS shipping_priority,
    ROUND((15.00 + (random() * 1250.00))::numeric, 2) AS total_amount,
    (ARRAY['WH-ORD-01', 'WH-DFW-02', 'WH-ATL-03', 'WH-LAX-04', 'WH-JFK-05'])[1 + floor(random() * 5)::int] AS warehouse_code,
    jsonb_build_object(
        'item_count', 1 + floor(random() * 9)::int,
        'carrier', (ARRAY['FEDEX', 'UPS', 'DHL', 'USPS'])[1 + floor(random() * 4)::int],
        'package_weight_kg', ROUND((0.45 + (random() * 14.50))::numeric, 2),
        'gift_wrap', (random() < 0.12)
    ) AS metadata
FROM generate_series(1, 3850000) AS g(id)
CROSS JOIN LATERAL (
    SELECT 
        CASE 
            WHEN random() < 0.0048 THEN 'AWAITING_DISPATCH'
            WHEN random() < 0.1548 THEN 'SHIPPED'
            WHEN random() < 0.9048 THEN 'DELIVERED'
            WHEN random() < 0.9748 THEN 'RETURNED'
            ELSE 'CANCELLED'
        END AS val
) AS status;

-- Step 5: Primary Key Constraint Attachment
-- Architectural Intent: Attached after bulk insertion to avoid write-overhead.
ALTER TABLE orders ADD CONSTRAINT pk_orders PRIMARY KEY (order_id);

-- Step 6: Query Planner Statistics Refresh & Table Heap Diagnostic
VACUUM ANALYZE orders;

-- Reset session defaults
SET synchronous_commit = on;

-- Step 7: Empirical Data Distribution & Storage Verification Audit
SELECT 
    fulfillment_status,
    COUNT(*) AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS percentage_of_total,
    MIN(order_timestamp)::timestamp(0) AS earliest_order,
    MAX(order_timestamp)::timestamp(0) AS latest_order
FROM orders
GROUP BY fulfillment_status
ORDER BY row_count ASC;

SELECT 
    pg_size_pretty(pg_relation_size('orders')) AS table_heap_size,
    pg_size_pretty(pg_total_relation_size('orders')) AS total_footprint_with_pk,
    (SELECT relpages FROM pg_class WHERE relname = 'orders') AS total_buffer_pages;
