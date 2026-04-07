# SEMANTIC_NOTES — Preparação para Consumo por IA

Este documento orienta agentes de IA (LLMs) sobre como gerar SQL correto a partir dos modelos
do projeto FinLend. Sem essas orientações, o agente cometerá erros previsíveis e silenciosos.

---

## Modelos disponíveis e o que cada um responde

### `revenue_report`
Granularidade: uma linha por transação.
Particionado por `transaction_date` (dia).

**Perguntas que este modelo responde:**
- Volume e valor de transações Pix de um merchant em um período
- Impacto financeiro de chargebacks em um mês
- Receita bruta vs. líquida por método de pagamento
- Transações ainda não liquidadas (settlement_id IS NULL)
- Evolução diária de receita por status

**Exemplo de uso correto:**
```sql
-- Volume de transações Pix do merchant X no último mês
SELECT
    COUNT(*) AS total_transacoes,
    SUM(`Valor Bruto BRL`) AS volume_bruto
FROM `projeto.dataset.revenue_report`
WHERE `ID do Merchant` = 'merchant_x'
    AND `Metodo de Pagamento` = 'pix'
    AND transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
```

---

### `merchant_summary`
Granularidade: uma linha por merchant (histórico completo — sem filtro de período).

**Perguntas que este modelo responde:**
- Merchants com taxa de chargeback acima de X%
- Ranking de merchants por receita total
- Merchants com primeira transação em determinado período (análise de ativação)
- Comparação de volume e taxas entre merchants

**Exemplo de uso correto:**
```sql
-- Merchants com taxa de chargeback acima de 2% no acumulado
SELECT
    `ID do Merchant`,
    `Nome do Merchant`,
    `Taxa de Chargeback`,
    `Total de Chargebacks`
FROM `projeto.dataset.merchant_summary`
WHERE `Taxa de Chargeback` > 0.02
ORDER BY `Taxa de Chargeback` DESC
```

---

### `int_finance_revenue_base`
Granularidade: uma linha por transação. Nomes de coluna em snake_case.
**Uso recomendado:** quando precisar de aggregations complexas ou joins adicionais.
Prefira `revenue_report` ou `merchant_summary` para análises simples.

---

## Armadilhas que um agente cometeria sem orientação

### 1. Usar `Valor Bruto BRL` para calcular receita total
**Armadilha:** `SUM("Valor Bruto BRL")` sempre dá resultado positivo — ignora estornos e chargebacks.
**Correto:** `SUM("Impacto no Resultado BRL")` — já considera o sinal por status.
**Como a documentação previne:** a descrição de "Valor Bruto BRL" alerta explicitamente para não usar
esta coluna em cálculos de receita; a de "Impacto no Resultado BRL" instrui sobre o uso correto.

### 2. Filtrar settlement_id IS NOT NULL como "filtro de qualidade"
**Armadilha:** O agente pode assumir que linhas com settlement_id = NULL são dados ruins e filtrá-las.
**Correto:** settlement_id = NULL significa transação ainda não liquidada — dado válido e esperado.
**Como a documentação previne:** todas as ocorrências de settlement_id têm a nota "NULL indica transação
ainda não liquidada — não tratar como erro."

### 3. Não filtrar por transaction_date ao consultar revenue_report
**Armadilha:** Fazer `SELECT * FROM revenue_report WHERE "ID do Merchant" = 'x'` sem filtrar por data
causa full scan da tabela inteira — ignora a partição e multiplica o custo da query.
**Correto:** Sempre incluir `WHERE transaction_date BETWEEN ...` ou `transaction_date >= ...`.
**Como a documentação previne:** a descrição do campo `transaction_date` instrui explicitamente sobre
o uso da partição para redução de custo.

### 4. Confundir `Valor Liquido BRL` com `Valor Bruto BRL`
**Armadilha:** O agente pode usar `Valor Liquido BRL` para calcular o faturamento da plataforma,
mas esse campo representa o que o merchant recebe — já deduzidas as taxas.
**Correto:** `Valor Bruto BRL` é o valor da transação; `Taxa BRL` é a receita da plataforma;
`Valor Liquido BRL` é o repasse ao merchant.
**Como a documentação previne:** as descrições de cada campo distinguem explicitamente a perspectiva
(plataforma vs. merchant).

### 5. Usar `merchant_summary` com filtro de período
**Armadilha:** `WHERE "Ultima Transacao" >= DATE_SUB(...)` no merchant_summary não filtra
transações de um período — filtra merchants pela data da última transação, não pela janela analítica.
**Correto:** Para análise de um período específico, usar `revenue_report` e agregar com GROUP BY merchant.
**Como a documentação previne:** a descrição do modelo alerta que ele agrega o histórico completo,
sem filtro de período pré-aplicado.

### 6. Assumir que `Total de Transacoes` em merchant_summary conta apenas aprovadas
**Armadilha:** O nome sugere "total de transações", mas inclui refunded e chargeback.
**Correto:** Filtrar por status no `revenue_report` antes de agregar se precisar apenas de captured.
**Como a documentação previne:** o modelo tem um TODO explícito e a descrição alerta sobre a inclusão
de todos os status na contagem.

---

## O que falta para uma camada semântica completa

### 1. Métricas pré-calculadas (MetricFlow / dbt Semantic Layer)
Os modelos atuais expõem colunas — não métricas. Um agente ainda precisa saber escrever
`SUM("Impacto no Resultado BRL")` para obter receita. Com MetricFlow, a métrica `receita_total`
estaria definida uma vez e o agente a chamaria pelo nome, sem precisar conhecer a coluna correta.

### 2. Tabela de referência de MCC
O campo `Codigo MCC` é um código numérico sem descrição. Para responder "Qual o volume de
transações de restaurantes?", o agente precisaria saber que restaurantes têm MCC 5812/5813.
Uma tabela de referência `dim_mcc` com `mcc_code → categoria → subcategoria` tornaria
esse tipo de pergunta respondível sem conhecimento prévio do padrão ISO 18245.

### 3. Dicionário de métodos de pagamento
O campo `Metodo de Pagamento` tem valores como `pix`, `credit_card`, `debit_card`, `boleto`.
Sem um `accepted_values` ou dimensão de referência, o agente pode usar valores incorretos
ao filtrar (ex: `credit` em vez de `credit_card`).

### 4. Dimensão de tempo calendário
Perguntas como "compare Q1 vs Q2" ou "qual foi o melhor mês do ano" requerem que o agente
construa lógica de calendário ad-hoc. Uma tabela `dim_calendar` com semana, mês, trimestre,
ano e flags de dias úteis permitiria JOINs diretos para esse tipo de análise.

### 5. Snapshot de merchants (SCD Tipo 2)
Hoje, `merchant_name` e `mcc_code` refletem o estado atual do cadastro. Se um merchant
mudou de nome, relatórios históricos mostrarão o nome novo para transações antigas — dado incorreto.
Um snapshot dbt criaria `valid_from`/`valid_to` e a flag `is_current`, permitindo o agente
a fazer JOINs com o merchant correto para a época de cada transação.

### 6. Metadados de freshness acessíveis via query
O schema.yml tem configuração de `freshness`, mas o agente não consegue consultar isso em SQL.
Uma view `data_freshness` que expõe o `MAX(loaded_at)` de cada tabela fonte permitiria que
o agente respondesse "os dados estão atualizados?" antes de responder a pergunta de negócio.
