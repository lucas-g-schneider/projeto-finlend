{{
    config(
        materialized='table'
    )
}}

/*
Modelo intermediário que aplica regras de negócio de receita.
Une transações, merchants e settlements para calcular o impacto financeiro de cada transação.
Os JOINs acontecem aqui — responsabilidade da camada intermediate.
Os marts consomem este modelo sem reaplicar lógica de join ou deduplicação.
*/

WITH transactions_with_merchants AS (

    SELECT
        transactions.transaction_id,
        transactions.merchant_id,
        transactions.customer_id,
        transactions.amount_brl,
        transactions.status,
        transactions.payment_method,
        DATE(transactions.created_at) AS transaction_date,
        transactions.created_at,
        merchants.trade_name AS merchant_name,
        merchants.mcc_code

    FROM {{ ref('stg_raw_transactions') }} AS transactions
    LEFT JOIN {{ ref('stg_raw_merchants') }} AS merchants
        ON transactions.merchant_id = merchants.merchant_id

    -- Filtra apenas status com impacto financeiro relevante.
    WHERE transactions.status IN ('captured', 'refunded', 'chargeback')

),

transactions_with_settlements AS (

    SELECT
        transactions_merchants.transaction_id,
        transactions_merchants.merchant_id,
        transactions_merchants.merchant_name,
        transactions_merchants.mcc_code,
        transactions_merchants.customer_id,
        transactions_merchants.amount_brl,
        transactions_merchants.status,
        transactions_merchants.payment_method,
        transactions_merchants.transaction_date,
        transactions_merchants.created_at,
        settlements.settlement_id,
        settlements.net_amount_brl,
        settlements.fee_amount_brl,
        settlements.settlement_date,
        settlements.paid_at,

        /*
        Deduplicação: uma transação pode aparecer em mais de um settlement em casos de
        reprocessamento ou correção. Mantemos apenas o settlement mais recente.
        Esta lógica existia no legado de forma implícita após o produto cartesiano.
        Aqui é explícita, isolada e auditável.
        */
        ROW_NUMBER() OVER (
            PARTITION BY transactions_merchants.transaction_id
            ORDER BY settlements.settlement_date DESC
        ) AS settlement_rank

    FROM transactions_with_merchants AS transactions_merchants
    LEFT JOIN {{ ref('stg_raw_settlements') }} AS settlements
        ON transactions_merchants.transaction_id = settlements.transaction_id

)

SELECT
    transaction_id,
    merchant_id,
    merchant_name,
    mcc_code,
    customer_id,
    amount_brl,
    status,
    payment_method,
    transaction_date,
    created_at,
    settlement_id,
    net_amount_brl,
    fee_amount_brl,
    settlement_date,
    paid_at,

    CASE
        WHEN status = 'captured' THEN amount_brl
        WHEN status IN ('refunded', 'chargeback') THEN -amount_brl
    END AS revenue_impact

    /*
    TODO: confirmar com o time financeiro se chargebacks têm tarifa adicional
    além do estorno do valor que deve ser incorporada ao revenue_impact.
    */

FROM transactions_with_settlements
WHERE settlement_rank = 1
    /*
    settlement_rank = 1 mantém transações SEM settlement (LEFT JOIN sem match):
    o LEFT JOIN produz uma única linha com settlement_id = NULL,
    que recebe settlement_rank = 1 e é preservada — comportamento correto.
    */
