{{ config(materialized='table') }}

SELECT
    merchant_id,
    merchant_name,
    mcc_code,
    COUNT(*) as total_transactions,
    SUM(revenue_impact) as total_revenue,
    SUM(fee_amount) as total_fees,
    SUM(CASE WHEN status = 'chargeback' THEN 1 ELSE 0 END) as chargebacks,
    SUM(CASE WHEN status = 'chargeback' THEN 1 ELSE 0 END) / COUNT(*) as chargeback_rate,
    MIN(transaction_date) as first_transaction,
    MAX(transaction_date) as last_transaction
FROM {{ ref('revenue_report') }}
GROUP BY 1, 2, 3