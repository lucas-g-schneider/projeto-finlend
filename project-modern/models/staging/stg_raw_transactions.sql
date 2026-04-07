{{
    config(
        materialized='table'
    )
}}

/*
loaded_at é provido pela equipe de engenharia durante a ingestão dos dados.
Não usamos CURRENT_TIMESTAMP() pois geraria o timestamp de execução do dbt,
não o momento real de ingestão — tornando o campo inutilizável para source freshness
e como campo de controle em modelos incrementais.
*/

SELECT
    transaction_id,
    merchant_id,
    customer_id,
    amount_cents,
    CAST(amount_cents AS FLOAT64) / 100 AS amount_brl,
    LOWER(TRIM(status)) AS status,
    payment_method,
    created_at,
    updated_at,
    loaded_at

    /*
    Coluna metadata intencionalmente excluída: campo JSON volumoso não consumido
    por nenhum modelo downstream. Mantê-la propagaria bytes desnecessários em cada
    scan (custo BigQuery). Se necessária, criar modelo dedicado acessando raw.transactions.
    */

FROM {{ source('raw', 'transactions') }}
WHERE status != 'test'
