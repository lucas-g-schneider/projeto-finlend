{{
    config(
        materialized='table'
    )
}}

/*
O campo transaction_ids em raw.settlements é um ARRAY de IDs.
O modelo legado fazia: ON t.transaction_id IN UNNEST(s.transaction_ids) dentro do JOIN,
gerando um produto cartesiano implícito — principal causa do custo elevado no BigQuery.

Correção: normalizamos o array com CROSS JOIN UNNEST, gerando uma linha por transaction_id.
O JOIN nos modelos downstream passa a ser por igualdade simples, eliminando o cartesiano.
*/

SELECT
    settlement_id,
    transaction_id,
    CAST(net_amount_cents AS FLOAT64) / 100 AS net_amount_brl,
    CAST(fee_amount_cents AS FLOAT64) / 100 AS fee_amount_brl,
    settlement_date,
    paid_at,
    loaded_at

FROM {{ source('raw', 'settlements') }}
CROSS JOIN UNNEST(transaction_ids) AS transaction_id
