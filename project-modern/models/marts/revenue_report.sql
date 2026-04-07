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

/*
Mart de relatório de receita. Dados prontos para consumo por analistas e BI.
Todas as regras de negócio já foram aplicadas em int_finance_revenue_base.
Colunas com nomes descritivos para facilitar leitura direta no BigQuery e em dashboards.
*/

SELECT
    transaction_id AS "ID da Transacao",
    merchant_id AS "ID do Merchant",
    merchant_name AS "Nome do Merchant",
    mcc_code AS "Codigo MCC",
    amount_brl AS "Valor Bruto BRL",
    status AS "Status da Transacao",
    payment_method AS "Metodo de Pagamento",
    transaction_date, -- campo de partição — mantido sem alias para corresponder ao partition_by config
    created_at AS "Criado Em",
    settlement_id AS "ID do Settlement",
    net_amount_brl AS "Valor Liquido BRL",
    fee_amount_brl AS "Taxa BRL",
    settlement_date AS "Data do Settlement",
    paid_at AS "Pago Em",
    revenue_impact AS "Impacto no Resultado BRL"

FROM {{ ref('int_finance_revenue_base') }}
