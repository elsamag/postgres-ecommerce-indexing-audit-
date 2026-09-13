-- ===================================
-- ENTERPRISE PRACTICE:
-- Elsamag IT Solutions
--
-- AUTHOR & LEAD CONSULTANT:
-- Samuel Chinwendu Agu
--
-- PROJECT:
-- PostgreSQL E-Commerce Indexing Audit
--
-- REPOSITORY TARGET:
-- https://github.com/Elsamag/
-- postgres-ecommerce-indexing-audit
--
-- FILE:
-- src/03_composite_partial_indexes.sql
--
-- DIALECT:
-- PostgreSQL 15 / 16
-- ===================================

\timing on

-- Enforce timeout safety barrier
-- to prevent lock stalls
SET statement_timeout = '300s';

-- -----------------------------------
-- 1. TARGETED PARTIAL COVERING INDEX
-- -----------------------------------
-- Rationale:
-- Eliminates sequential table heap
-- scans by indexing only active rows
-- (0.48% of total volume) while
-- pre-sorting order_timestamp ASC.
CREATE INDEX CONCURRENTLY
IF NOT EXISTS
    idx_orders_unfulfilled_dispatch_queue
ON orders (
    order_timestamp ASC
)
INCLUDE (
    order_id,
    customer_id,
    total_amount,
    warehouse_code
)
WHERE
    fulfillment_status =
    'AWAITING_DISPATCH';

-- -----------------------------------
-- 2. COMPOSITE STATUS-TIMESTAMP INDEX
-- -----------------------------------
-- Rationale:
-- Accelerates secondary WMS sync
-- queries tracking transitions
-- across SHIPPED and DELIVERED states.
CREATE INDEX CONCURRENTLY
IF NOT EXISTS
    idx_orders_status_timestamp_composite
ON orders (
    fulfillment_status,
    order_timestamp DESC
)
INCLUDE (
    total_amount,
    warehouse_code
);

-- -----------------------------------
-- 3. PLANNER STATISTICS REFRESH
-- -----------------------------------
-- Update distribution histograms
-- so the Cost-Based Optimizer (CBO)
-- immediately selects index seeks.
ANALYZE orders;

-- -----------------------------------
-- 4. INTEGRITY & VALIDATION CHECK
-- -----------------------------------
-- Confirm indexes built concurrently
-- are valid and ready for reads.
SELECT
    c.relname AS index_name,
    i.indisvalid AS is_valid,
    i.indisready AS is_ready,
    pg_size_pretty(
        pg_relation_size(c.oid)
    ) AS disk_footprint
FROM pg_index i
JOIN pg_class c
    ON c.oid = i.indexrelid
WHERE c.relname IN (
    'idx_orders_unfulfilled_dispatch_queue',
    'idx_orders_status_timestamp_composite'
);

-- -----------------------------------
-- 5. EMERGENCY ROLLBACK DEFINITIONS
-- -----------------------------------
-- In event of index rollback:
-- DROP INDEX CONCURRENTLY IF EXISTS
--     idx_orders_unfulfilled_dispatch_queue;
-- DROP INDEX CONCURRENTLY IF EXISTS
--     idx_orders_status_timestamp_composite;
