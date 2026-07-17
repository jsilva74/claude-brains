# memory-freshness

## ADDED Requirements

### Requirement: Soft-delete de memórias via `archived_at`

A tabela `memories` SHALL possuir a coluna nullable `archived_at` (NULL = ativa). Toda remoção decidida por modelo (distill `obsolete`, GC) MUST ser arquivamento (`archived_at = datetime('now')`), nunca DELETE físico. Memórias arquivadas MUST ser excluídas de inject (SessionStart), FTS-recall (UserPromptSubmit), da lista de dedup do distill e dos resultados padrão do CLI. A migração de schema MUST ser idempotente e aplicada automaticamente por `brains_ensure_db`.

#### Scenario: Memória arquivada some da injeção

- **WHEN** uma memória tem `archived_at` não-nulo e o hook SessionStart ou UserPromptSubmit roda para o projeto
- **THEN** ela não aparece no contexto injetado

#### Scenario: Migração em DB existente

- **WHEN** `brains_ensure_db` roda contra um DB criado por versão anterior (sem a coluna)
- **THEN** a coluna `archived_at` é adicionada sem perda de dados e todas as memórias existentes permanecem ativas

#### Scenario: Purge após 30 dias

- **WHEN** o pós-distill roda e existem memórias com `archived_at` anterior a 30 dias
- **THEN** essas linhas são deletadas fisicamente (e saem do índice FTS via trigger)

### Requirement: Reconciliação de obsoletas no distill

O contrato JSON do distiller SHALL aceitar o campo opcional `obsolete: [títulos]`, referenciando títulos da lista "Existing memories" que a sessão comprovadamente invalidou. `parse-distill.py` MUST converter cada título em UPDATE de arquivamento restrito ao projeto. O prompt MUST instruir postura conservadora: marcar apenas com evidência explícita no transcript. Nenhum call de modelo adicional MUST ser introduzido por esta reconciliação.

#### Scenario: Sessão invalida memória existente

- **WHEN** o transcript mostra que um trabalho registrado como `state` "em andamento" foi concluído e o distiller retorna esse título em `obsolete`
- **THEN** a memória correspondente é arquivada no mesmo distill, sem call extra

#### Scenario: Título inexistente em `obsolete`

- **WHEN** o distiller retorna em `obsolete` um título que não existe no projeto
- **THEN** o UPDATE é um no-op e o restante do distill prossegue normalmente

### Requirement: Títulos estáveis como chave de identidade

O prompt do distiller SHALL exigir títulos estáveis — sem versão, data ou status embutidos — de modo que atualizações do mesmo fato colidam no upsert `(project_id, title)` em vez de criar memórias paralelas.

#### Scenario: Fato atualizado entre releases

- **WHEN** uma sessão registra o status de release de um plugin que já possui memória de release anterior
- **THEN** o distiller reutiliza o título estável existente e o upsert sobrescreve o body, sem criar uma segunda memória versionada

### Requirement: Retenção de memórias `state`

Após cada distill bem-sucedido, o sistema SHALL manter ativas no máximo K memórias `state` por projeto (padrão K=5, configurável via `BRAINS_STATE_KEEP`), arquivando as excedentes mais antigas por `updated_at`, usando SQL puro (sem call de modelo).

#### Scenario: Sexto state chega

- **WHEN** um distill insere uma memória `state` e o projeto passa a ter 6 states ativos
- **THEN** o state mais antigo (por `updated_at`) é arquivado, restando 5 ativos

### Requirement: GC automático gated no pós-distill

Após um distill bem-sucedido, o worker detached SHALL avaliar um gate barato (SQL puro) e disparar consolidação quando `distills_since_gc >= 5` E (`active_count > threshold` OU `distills_since_gc >= 25`), com threshold padrão 120 (configurável via env). O bookkeeping (contador de distills e timestamp do último GC por projeto) SHALL residir na tabela `meta`. O gate e o GC MUST rodar inteiramente no worker detached — latência zero para a sessão. Um lock atômico MUST impedir GC concorrente, com steal de lock órfão por mtime superior a 10 minutos.

#### Scenario: Gate não atingido

- **WHEN** um distill conclui e o projeto tem menos memórias ativas que o threshold e menos de 25 distills desde o último GC
- **THEN** nenhum call de modelo adicional ocorre; o custo é apenas o SELECT do gate

#### Scenario: Acúmulo dispara GC

- **WHEN** um distill conclui com `active_count > 120` e pelo menos 5 distills desde o último GC
- **THEN** o passo de GC é executado no mesmo worker detached e o bookkeeping é atualizado

#### Scenario: GC concorrente bloqueado

- **WHEN** dois workers concluem distill simultaneamente e ambos atingem o gate
- **THEN** apenas um executa o GC; o outro sai silenciosamente ao encontrar o lock

### Requirement: Consolidação por modelo com saída conservadora e input bounded

O passo de GC SHALL executar um único call haiku isolado (mesmo padrão de isolamento do distill) sobre uma fatia de no máximo 80 memórias ativas (cap de 32k chars), mais antigas primeiro. A saída SHALL seguir o contrato `{"archive": [títulos], "update": [{title, type, body}]}`. O parser MUST emitir apenas UPDATEs (arquivamento e reescrita de body/type) — nunca INSERT nem DELETE. Falha de call ou parse MUST resultar em exit silencioso sem avançar o bookkeeping, permitindo retry no próximo gate.

#### Scenario: Duplicatas semânticas consolidadas

- **WHEN** o GC roda sobre uma fatia contendo duas memórias que descrevem o mesmo fato com títulos diferentes
- **THEN** uma vira canônica (body consolidado via `update`) e a outra é arquivada via `archive`

#### Scenario: Call falha

- **WHEN** o `claude -p` do GC retorna vazio ou JSON inválido
- **THEN** nenhuma alteração ocorre no DB, o bookkeeping não avança e o próximo gate poderá tentar de novo

#### Scenario: Corpus maior que a fatia

- **WHEN** o projeto tem mais memórias ativas que o tamanho da fatia
- **THEN** o GC processa apenas a fatia mais antiga; triggers subsequentes cobrem o restante incrementalmente

### Requirement: Comandos CLI de manutenção

O CLI SHALL oferecer: `gc [path]` (força consolidação imediata, ignorando o gate mas respeitando o lock), `archived [path]` (lista memórias arquivadas com data), e `restore <title>` (reativa uma memória arquivada do projeto corrente). O comando `forget` SHALL passar a arquivar em vez de deletar fisicamente.

#### Scenario: Restore de arquivamento indevido

- **WHEN** o usuário executa `restore <title>` para uma memória arquivada
- **THEN** `archived_at` volta a NULL e a memória reaparece em inject/recall

#### Scenario: Forget recuperável

- **WHEN** o usuário executa `forget <title>`
- **THEN** a memória é arquivada (não deletada) e permanece recuperável via `restore` até o purge de 30 dias
