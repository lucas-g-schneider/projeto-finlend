# FinLend — Analytics Engineering

## Estrutura do Repositório

```
projeto-finlend/
├── project-legacy/                  # Projeto original, não alterado, serve como baseline
│   └── models/
│       ├── staging/
│       │   └── stg_transactions.sql
│       ├── marts/
│       │   ├── revenue_report.sql
│       │   └── merchant_summary.sql
│       └── schema.yml
├── project-modern/                  # Projeto refatorado
│   └── models/
│       ├── staging/
│       │   ├── stg_raw_transactions.sql + .yml
│       │   ├── stg_raw_merchants.sql    + .yml
│       │   └── stg_raw_settlements.sql  + .yml
│       ├── intermediate/
│       │   └── finance/
│       │       └── int_finance_revenue_base.sql + .yml
│       ├── marts/
│       │   ├── revenue_report.sql   + .yml
│       │   └── merchant_summary.sql + .yml
│       ├── tests/
│       │   └── assert_no_duplicate_transactions.sql
│       ├── schema.yml               (sources only, descrições de modelos estão nos .yml individuais)
│       └── SEMANTIC_NOTES.md
└── teste_tecnico_analytics_engineer.md
```

---

## Arquitetura de Camadas — Regras do Projeto

Uma decisão central deste projeto foi a introdução da camada **intermediate**, ausente no legado.
Cada camada tem responsabilidades bem definidas:

### Staging (`stg_source_tabela`)
- Relação 1:1 com a fonte raw
- Apenas transformações simples: cast de tipos, normalização (lower/trim), renomeação de colunas
- **Sem joins**, **sem regras de negócio**
- Materialização como `table` (não view) para evitar re-scan da fonte em cada uso

### Intermediate (`int_areadenegocio_regradenegocio`)
- Responsável pelos **joins** e **regras de negócio**
- Organizado por área de negócio (ex: `finance/`, `marketing/`, `produto/`)
- Aqui é onde a complexidade vive: isolada, documentada e testada
- Marts consomem desta camada, não precisam reaplicar lógica

### Mart (`nome_descritivo`)
- Dados prontos para consumo por analistas, BI e produto
- Colunas com **nomes descritivos** em português para facilitar leitura direta
- Joins podem ocorrer, mas a regra é: se possível, deixar o intermediate fazer o trabalho pesado
- Sem lógica de negócio nova, apenas seleção e apresentação

---

## Parte 1 — Diagnóstico

### Framework: Três Stakeholders, Três Problemas

Antes de olhar para o código, mapeei quem reportou o quê e por que isso importa. O projeto tem três stakeholders com dores distintas, cada decisão de refatoração precisa ser justificada por uma dessas dores, não por preferência técnica.

| Stakeholder | Problema Reportado | Natureza da Dor |
|---|---|---|
| **CFO** | "A conta do BigQuery triplicou" | Custo mensurável, impacto financeiro imediato |
| **Analistas** | "Os números nunca batem" | Bloqueio operacional, analista sem dado confiável está parado |
| **Time de Produto** | Quer IA para perguntas de negócio | Demanda de nova feature, ainda não bloqueado, mas quer evoluir |

A priorização que segue decorre diretamente disso.

---

### Problemas Identificados — Por Stakeholder

#### CFO — Custo do BigQuery

**Problema 1 (CRÍTICO) — `IN UNNEST(s.transaction_ids)` no JOIN de settlements**

`revenue_report.sql` legado, linha 32:
```sql
LEFT JOIN {{ source('raw', 'settlements') }} s
    ON t.transaction_id IN UNNEST(s.transaction_ids)
```
O campo `transaction_ids` em settlements é um ARRAY. Usar `IN UNNEST()` dentro de uma condição de JOIN força o BigQuery a executar um produto cartesiano implícito entre as tabelas antes de aplicar o filtro. Em escala (ex: 1M transações × 500k settlements com arrays de 100 elementos), isso pode gerar 50 bilhões de combinações intermediárias. O BigQuery cobra por bytes processados, esta linha é a principal candidata a ter triplicado a fatura.

**Impacto secundário para os Analistas:** além do custo, o produto cartesiano pode selecionar o settlement errado para uma transação quando há reprocessamentos, gerando `net_amount` e `fee_amount` incorretos nos relatórios. É um problema de custo E de dados incorretos simultaneamente.

**Correção implementada:** `stg_raw_settlements.sql` faz o `UNNEST` uma única vez com `CROSS JOIN UNNEST(transaction_ids)`, normalizando o array em linhas. O JOIN no intermediate passa a ser por igualdade simples — sem produto cartesiano.

---

**Problema 2 (CRÍTICO) — `stg_transactions` sem materialização**

`stg_transactions.sql` legado não tem bloco `{{ config(...) }}`, então o dbt usa `view` como padrão. Uma view não armazena dados, re-executa a query de origem toda vez que é consultada. Como `revenue_report` e `merchant_summary` dependem de `stg_transactions`, a tabela `raw.transactions` é varrida integralmente a cada run de cada um desses modelos.

**Correção implementada:** `stg_raw_transactions.sql` com `materialized='table'`. A fonte raw é escaneada uma vez por run e o resultado é armazenado, eliminando os scans redundantes.

---

**Problema 3 (CRÍTICO) — Coluna `metadata` propagada por todo o pipeline**

`stg_transactions.sql` legado inclui `metadata` no SELECT. Colunas `metadata` em sistemas financeiros carregam JSON volumoso (payload do gateway, device info, geolocalização). Nenhum modelo downstream usa esta coluna. No BigQuery, bytes processados incluem todas as colunas no SELECT, metadata desnecessária multiplica o custo de cada scan.

**Correção implementada:** `metadata` removida do `stg_raw_transactions.sql`. Decisão documentada em comentário no próprio modelo.

---

#### Analistas — Números que não Batem

**Problema 4 (ALTO) — Marts fazem JOIN direto em fontes raw**

`revenue_report.sql` legado faz `LEFT JOIN {{ source('raw', 'merchants') }}` e `LEFT JOIN {{ source('raw', 'settlements') }}` diretamente. Se a equipe de engenharia renomear `trade_name` para `name` em `raw.merchants`, o mart produz NULLs silenciosamente. O analista vê `merchant_name = NULL` sem conseguir identificar a origem.

**Correção implementada:** criação de `stg_raw_merchants.sql` e `stg_raw_settlements.sql`. O intermediate `int_finance_revenue_base` usa apenas `ref()`, nunca `source()` diretamente. Marts também consomem apenas via `ref()`.

---

**Problema 5 (ALTO) — Coluna `rn` vazando no output + `SELECT *`**

`revenue_report.sql` legado faz `SELECT *`, expondo a coluna `rn` (artefato do `ROW_NUMBER` de deduplicação) no schema final. Um analista que vê `rn` em uma ferramenta de BI pode usá-la inadvertidamente em filtros, gerando resultados errados.

**Correção implementada:** `revenue_report.sql` moderno lista colunas explicitamente. `rn` não existe mais no output, a deduplicação ocorre no intermediate com `settlement_rank` que também não vaza para os marts.

---

**Problema 6 (ALTO) — Zero testes no projeto**

O `schema.yml` legado não define nenhum teste. Sem `unique` em `transaction_id`, duplicatas somam o valor duas vezes. Sem `not_null` em `amount_cents`, um NULL entra silenciosamente e qualquer `SUM()` fica errado. Não há mecanismo de detecção — por isso "os números nunca batem" sem que ninguém saiba apontar onde.

**Correção implementada:** testes em todos os modelos via `.yml` individuais (`unique`, `not_null`, `accepted_values`). Teste singular `assert_no_duplicate_transactions.sql` valida a regra de deduplicação por settlement.

---

#### Time de Produto — Preparação para IA

**Problema 7 (MÉDIO) — `schema.yml` praticamente vazio**

As descrições legadas são `"staging transactions"`, `"report for revenue"` zero colunas documentadas. Um LLM não sabe a diferença entre `amount_brl`, `net_amount` e `revenue_impact` sem contexto semântico. Vai escolher a coluna errada e produzir respostas incorretas.

**Correção implementada:** cada modelo tem seu próprio `.yml` com descrição funcional por coluna. Campos com ambiguidade têm notas de atenção e TODOs para validação com o time de negócio. `SEMANTIC_NOTES.md` documenta armadilhas específicas para consumo por agentes de IA.

---

#### Outros Problemas Identificados (sem refatoração em código)

| # | Problema | Decisão |
|---|---|---|
| 8 | `chargeback_rate` sem `SAFE_DIVIDE` | Aplicado como padrão em `merchant_summary.sql` |
| 9 | `CURRENT_TIMESTAMP()` como `loaded_at` | Consideramos que a equipe de engenharia adiciona `loaded_at` na ingestão, selecionamos o campo diretamente, documentando na descrição da coluna que ele representa o momento de ingestão, não de execução do dbt |
| 10 | `GROUP BY 1, 2, 3` posicional | Todos os GROUP BY do projeto moderno usam nomes de coluna explícitos |
| 11 | Ausência de `dbt_project.yml` | Consideramos que o arquivo existe no repositório real, este projeto trabalha com uma amostra de modelos |

---

## Parte 2 — Refatoração Seletiva

### Os 3 problemas escolhidos para os Analistas — e por quê

Os três problemas escolhidos são **Problemas 4, 5 e 6** (staging para merchants/settlements, `rn` + `SELECT *`, e testes). Todos endereçam diretamente: "os números nunca batem."

**Por que esses 3 e não os de custo (1, 2, 3)?**

Os problemas de custo foram tratados no **Desafio Extra (Parte 5)**, pois demandam tratamento conjunto, o `IN UNNEST` só pode ser corretamente corrigido junto com a criação do `stg_raw_settlements`. Separá-los seria artificialmente dividir uma solução atômica.

Os analistas estão **bloqueados operacionalmente**: sem dados confiáveis, não produzem. Testes e schema limpo são as correções que mais rapidamente restauram a confiança nos dados.

**Por que não os de menor severidade (8-11)?**

Foram todos endereçados de forma pontual no código (SAFE_DIVIDE aplicado, GROUP BY nomeado, loaded_at correto, dbt_project.yml assumido existente) sem necessitar de seção dedicada, pois são melhorias de padrão, não causas raiz da reclamação.

---

### Camada Intermediate — Por que é Essencial

A ausência da camada intermediate no legado foi uma das causas raiz de múltiplos problemas:

- **Joins em marts** (Problema 4): sem intermediate para fazer JOINs, os marts acessavam raw diretamente
- **Lógica duplicada**: deduplicação e cálculo de `revenue_impact` estavam misturados no mesmo modelo com seleção de colunas
- **Testabilidade zero**: não havia modelo estável para testar as regras de negócio isoladamente

O `int_finance_revenue_base` concentra toda a lógica: filtro de status, join transactions+merchants+settlements, deduplicação por settlement mais recente e cálculo de revenue_impact. Os marts consomem sem reaplicar nada.

---

## Parte 3 — Preparação para IA

Ver: `project-modern/models/schema.yml` (fontes), arquivos `.yml` individuais de cada modelo (colunas) e `project-modern/SEMANTIC_NOTES.md` (guia para agentes de IA).

**Estratégia de documentação:**

- Descrições funcionais por coluna, o que o campo representa no contexto de negócio da FinLend
- Notas de `ATENÇÃO` em campos com semântica não-óbvia (ex: `settlement_id = NULL` é dado válido)
- `TODO` explícito em colunas que precisam de validação com o time de negócio (ex: MCC codes, lista de métodos de pagamento), sinaliza ao agente que aquele campo tem incerteza e que é um trabalho em conjunto analistas + engenharia
- Descrições de filtros obrigatórios para aproveitar partição e evitar full scan

O `SEMANTIC_NOTES.md` documenta:
1. Quais perguntas de negócio cada modelo consegue responder
2. As 6 armadilhas mais prováveis de um agente sem orientação (e como a documentação as previne)
3. O que falta para uma camada semântica completa (MetricFlow, dim_mcc, dim_calendar, snapshot SCD2)

---

## Parte 4 — Documento de Decisões

### Meu Processo

Antes de abrir qualquer arquivo SQL, mapeei os três stakeholders e o que cada um estava sentindo. Esse passo foi intencional: em projetos de dados legados, o código quase sempre reflete as pressões humanas que o criaram, urgência, troca de equipe, falta de padrão. Entender quem está reclamando e do quê direciona a priorização muito melhor do que uma auditoria técnica cega.

**Como priorizei:**

Hierarquia organizacional colocaria o CFO primeiro. Mas priorizei os analistas na refatoração porque estão **bloqueados operacionalmente**, um analista sem dado confiável não produz nada. O CFO pode aguardar um diagnóstico técnico detalhado; um analista não consegue trabalhar enquanto os números não batem.

A solução para o CFO foi endereçada no Desafio Extra, onde tem espaço para o tratamento correto e conjunto (o problema 1 de custo só pode ser resolvido junto com a criação do staging de settlements).

O time de produto foi endereçado na Parte 3, e de forma sequencial: primeiro corrigir a arquitetura, depois documentar. Documentar um modelo com `SELECT *` e sem testes seria construir sobre areia.

---

### Uso de IA

O **Claude Code** foi utilizado como parceiro de **pair programming**, como um desenvolvedor pleno ao lado, acelerando execução para que eu ficasse na tomada de decisões. O uso foi iterativo: a cada entrega do Claude, eu revisava, questionava e redirecionava. Abaixo os momentos concretos onde o senso crítico foi necessário.

**Rodada 1 — Diagnóstico**

Pedi o diagnóstico do projeto legado. O Claude entregou uma lista técnica ordenada por severidade, válida. Mas o output estava centrado em código, sem considerar quem estava com dor. Redirecionei: mapeei os 3 stakeholders (CFO, Analistas, Produto), suas dores específicas e determinei que cada decisão de refatoração precisaria ser justificada por uma dessas dores, não por preferência técnica. O Claude reescreveu o diagnóstico com esse framework.

**Rodada 2 — Arquitetura e README**

O Claude propôs uma estrutura de dois layers (staging + marts), o que estava no legado, só limpa. Intervim adicionando a camada **intermediate**, que estava ausente e era a causa raiz de vários problemas (JOINs nos marts, lógica duplicada, dificuldade de teste). Defini também as regras de cada camada: staging é 1:1 com a fonte, intermediate é onde os JOINs acontecem, mart é só apresentação. O Claude seguiu essas regras, mas precisei defini-las, ele não as propôs.

**Rodada 3 — "O que faria com mais tempo"**

O Claude gerou 8 itens para essa seção. Cortei para 4: incrementais, snapshot, freshness e CI/CD. Os outros (observabilidade, exposures, PII tagging, unit tests) são válidos mas não eram as prioridades reais e incluí-los todos passaria a impressão de uma lista de wishlist, não de priorização real. Além disso, detalho no README que os incrementais são uma decisão de time, não só técnica, essa nuance o Claude não havia incluído.

**Rodada 4 — Alertas e escalonamento**

O Claude propôs alertas por email direto ao CFO em falhas críticas. Corrigi: o email vai para o **tech lead**, que investiga antes de escalar. O CFO deve receber informação resolvida, não apenas "tivemos um erro". Essa distinção importa no contexto de uma fintech onde o CFO questiona custos.

**Rodada 5 — Qualidade do código**

O Claude gerou aliases curtos (`t`, `m`, `s`) e alinhamento de colunas com múltiplos espaços para "embelezar" o SQL. Corrigi os dois: aliases descritivos (`AS transactions`, `AS merchants`, `AS settlements`) aumentam a legibilidade para quem não conhece o modelo; alinhamento forçado cria trabalho de manutenção sem benefício real. Também padronizei comentários multi-linha para `/* */` em vez de `--` linha a linha.

---

### O Que Faria com Mais Tempo

Em ordem de prioridade:

**1. Incremental models para `stg_raw_transactions` e `int_finance_revenue_base`**

Full table rebuild em toda execução não escala. Modelos incrementais processam apenas registros novos usando `created_at` ou `loaded_at` como campo de controle. Impacto direto em custo e velocidade de run.

Esta é uma decisão de **time**, não apenas técnica: incremental requer alinhamento sobre o campo de controle, política de late-arriving data e janela de lookback. O time de analistas precisa participar, por isso foi uma escolha consciente não implementar agora, priorizando primeiro a correção da arquitetura e dos dados.

**2. Snapshot SCD Tipo 2 para `merchants`**

`trade_name` e `mcc_code` mudam ao longo do tempo. Hoje, um relatório histórico de 6 meses mostra o nome atual do merchant, não o nome que ele tinha na época da transação. Um dbt snapshot cria `valid_from`/`valid_to` e `is_current`, permitindo JOINs temporalmente corretos. Relatórios históricos ficam confiáveis.

**3. Freshness nos sources com alertas**

O `schema.yml` moderno já tem configuração de `freshness` e `loaded_at_field`. O próximo passo é conectar isso a alertas: se `raw.transactions` parar de receber dados por 24h, os analistas precisam saber **antes** de usar os dados, não depois de encontrar números errados. A importância do `loaded_at` vindo da ingestão (e não do dbt) é justamente essa: permite saber com precisão quando os dados foram carregados.

**4. CI/CD com `dbt test` em pull requests**

Qualquer alteração em modelo deve passar pelos testes antes de chegar em produção. Um pipeline de CI (GitHub Actions ou dbt Cloud) bloqueia merges com testes quebrados, aplica padrões de nomenclatura e valida a existência de documentação por coluna. Aumenta o nível de maturidade do time e elimina a dependência de revisão manual para pegar erros básicos.

---

## Parte 5 — Desafio Extra

### Custo (CFO)

Os três problemas de custo foram corrigidos de forma integrada:

1. **`IN UNNEST` no JOIN** → `stg_raw_settlements.sql` normaliza o array com `CROSS JOIN UNNEST`, JOIN downstream é por igualdade simples, sem produto cartesiano
2. **Staging sem materialização** → `stg_raw_transactions.sql` com `materialized='table'`, fonte raw escaneada uma vez por run
3. **`metadata` propagada** → removida do SELECT em `stg_raw_transactions.sql`, bytes processados reduzidos em toda a cadeia

---

### Teste de Negócio

`project-modern/models/tests/assert_no_duplicate_transactions.sql`

Valida que cada `transaction_id` aparece exatamente uma vez em `int_finance_revenue_base`. Uma duplicata indica falha na deduplicação por `settlement_rank`, o que causaria double-counting em `SUM(revenue_impact)` e, consequentemente, receita inflada em todos os relatórios downstream.

Este é exatamente o tipo de erro silencioso que gerava "os números nunca batem" sem que ninguém soubesse onde estava o problema.

---

### Orquestração (dbt Cloud)

#### Jobs e Frequência Recomendada

| Job | Frequência | Horário | Motivo |
|---|---|---|---|
| `production_full_refresh` | Semanal (domingo) | 02:00 BRT | Rebuild completo para consistência; horário de baixo tráfego |
| `production_incremental` | Diário | 06:00 BRT | Dados do dia anterior disponíveis antes do expediente dos analistas |
| `production_incremental` | Diário | 13:00 BRT | Segunda janela para transações da manhã |
| `ci_test` | A cada PR | — | Gatilhado por webhook do GitHub; bloqueia merge se testes falharem |

#### Alertas

**Slack** — canal `#data-alerts`:
- Qualquer falha em qualquer job de produção
- Source freshness fora do threshold (warn ou error)
- Timeout de job excedido

**Email** — tech lead (não o CFO diretamente):
- Falhas no job `production_full_refresh`
- O tech lead recebe a notificação, investiga a causa raiz e comunica o CFO com a situação **já mapeada** — não apenas "tivemos um problema". A informação que chega ao CFO deve ser mais resolvida do que o alerta bruto.

#### Dependências e Retries

```
stg_raw_transactions  ──┐
stg_raw_merchants     ──┤→ int_finance_revenue_base ──┬→ revenue_report
stg_raw_settlements   ──┘                             └→ merchant_summary
```

- `retries: 2` nos jobs de produção para falhas transitórias de rede/quota BigQuery
- `retry_delay_seconds: 300` (5 minutos entre tentativas)
- Source freshness check antes de cada run incremental, se a fonte estiver desatualizada, o job falha com mensagem clara antes de processar dados stale

#### Environments

| Environment | Target | Materialização padrão | Uso |
|---|---|---|---|
| `dev` | dataset pessoal do dev | `view` | Desenvolvimento local |
| `ci` | dataset efêmero por PR | `view` | Testes de CI |
| `production` | dataset compartilhado | `table` | Consumo pelos analistas e produto |
