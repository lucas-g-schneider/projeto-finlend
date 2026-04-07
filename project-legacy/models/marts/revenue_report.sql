{{
    config(
        materialized='table',
        partition_by={
            "field": "transaction_date",
            "data_type": "date",
            "granularity": "day"
        }
    )
}}

WITH base AS (
    SELECT
        t.transaction_id,
        t.merchant_id,
        m.trade_name as merchant_name,
        m.mcc_code,
        t.amount_brl,
        t.status,
        t.payment_method,
        DATE(t.created_at) as transaction_date,
        t.created_at,
        s.settlement_id,
        s.net_amount_cents / 100 as net_amount,
        s.fee_amount_cents / 100 as fee_amount,
        s.settlement_date,
        s.paid_at
    FROM {{ ref('stg_transactions') }} t
    LEFT JOIN {{ source('raw', 'merchants') }} m
        ON t.merchant_id = m.id
    LEFT JOIN {{ source('raw', 'settlements') }} s
        ON t.transaction_id IN UNNEST(s.transaction_ids)
    WHERE t.status IN ('captured', 'refunded', 'chargeback')
)
SELECT
    *,
    CASE
        WHEN status = 'captured' THEN amount_brl
        WHEN status = 'refunded' THEN -amount_brl
        WHEN status = 'chargeback' THEN -amount_brl
    END as revenue_impact,
    ROW_NUMBER() OVER (
        PARTITION BY transaction_id
        ORDER BY settlement_date DESC
    ) as rn
FROM base
QUALIFY rn = 1