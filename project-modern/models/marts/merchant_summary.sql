{{
    config(
        materialized='table'
    )
}}

/*
Mart de resumo por merchant. Agrega métricas financeiras e operacionais.
Consome de int_finance_revenue_base (não de revenue_report) para usar nomes de colunas
limpos na agregação — evita referenciar colunas com aspas no GROUP BY.
SAFE_DIVIDE previne divisão por zero. GROUP BY com nomes explícitos, não posições numéricas.
*/

SELECT
    merchant_id AS "ID do Merchant",
    merchant_name AS "Nome do Merchant",
    mcc_code AS "Codigo MCC",
    COUNT(*) AS "Total de Transacoes",
    SUM(revenue_impact) AS "Receita Total BRL",
    SUM(fee_amount_brl) AS "Total de Taxas BRL",
    SUM(CASE WHEN status = 'chargeback' THEN 1 ELSE 0 END) AS "Total de Chargebacks",
    SAFE_DIVIDE(
        SUM(CASE WHEN status = 'chargeback' THEN 1 ELSE 0 END),
        COUNT(*)
    ) AS "Taxa de Chargeback",
    MIN(transaction_date) AS "Primeira Transacao",
    MAX(transaction_date) AS "Ultima Transacao"

FROM {{ ref('int_finance_revenue_base') }}

GROUP BY
    merchant_id,
    merchant_name,
    mcc_code
