-- Teste singular: assert_no_duplicate_transactions
--
-- Valida que cada transaction_id aparece exatamente uma vez em int_finance_revenue_base.
--
-- Regra de negócio testada:
--   Após a deduplicação por settlement_rank = 1 (settlement mais recente por transação),
--   não deve existir nenhum transaction_id duplicado no modelo intermediário.
--
-- Por que esse teste é crítico:
--   Uma duplicata em transaction_id significa que a deduplicação falhou — por exemplo,
--   se dois settlements tiverem a mesma settlement_date para a mesma transação.
--   Uma duplicata resulta em double-counting no SUM(revenue_impact), inflando ou distorcendo
--   todos os relatórios financeiros downstream (revenue_report e merchant_summary).
--   Este era o tipo de erro que gerava a reclamação "os números nunca batem".
--
-- Comportamento esperado do teste dbt:
--   - Retorna 0 linhas → teste passa
--   - Retorna qualquer linha → teste falha (há duplicatas)

SELECT
    transaction_id,
    COUNT(*) AS occurrences
FROM {{ ref('int_finance_revenue_base') }}
GROUP BY transaction_id
HAVING COUNT(*) > 1
