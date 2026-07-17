# memory-freshness

## Why

Memories ficam stale e injetam informação errada em sessões futuras. Evidência no DB atual: `claude_brains_v1.2.1_live` e `v1.2.2_live` coexistem (títulos versionados derrotam o dedup por título); memórias `state` resolvidas (`deployment_incomplete_final_test`) continuam sendo injetadas como "em andamento"; e a janela de dedup de 40 títulos é menor que o corpus de projetos grandes (sif: 295, hseye: 283), deixando duplicação semântica crescer sem teto. Sem manutenção autônoma, o lixo acumula até gerar confusão — e depender de comando manual garante que nunca roda.

## What Changes

- **Reconciliação no distill**: o contrato JSON do distiller ganha campo `obsolete: [títulos]` — o modelo marca memórias existentes que a sessão invalidou; o parser as arquiva (soft-delete). Zero calls extras (mesmo call, mesmo worker detached).
- **Higiene de títulos**: o prompt do distiller passa a exigir títulos estáveis (sem versão/data/status embutidos), para que upserts colidam corretamente.
- **Retenção de `state`**: memórias `state` são efêmeras por natureza — apenas as N mais recentes por projeto permanecem ativas; as demais são arquivadas automaticamente (SQL puro, custo zero).
- **GC automático gated**: após um distill bem-sucedido, o worker (já detached) checa gates baratos (contagem de memórias > threshold OU N distills desde o último GC). Se disparado, um segundo call haiku consolida o corpus do projeto (merges + arquivamentos), com lock anti-concorrência e input bounded (fatias incrementais).
- **Soft-delete (`archived_at`)**: nenhuma decisão de modelo deleta fisicamente. Memórias arquivadas saem de inject/FTS imediatamente; purge física só após 30 dias. `/brains restore` reverte erros.
- **CLI**: `/brains gc` vira override manual ("limpa agora"); novos subcomandos `restore` e listagem de arquivadas.

## Capabilities

### New Capabilities

- `memory-freshness`: manutenção autônoma do corpus de memórias — reconciliação de obsoletas no distill, higiene de títulos, retenção de `state`, GC automático gated com soft-delete e recuperação.

### Modified Capabilities

<!-- stop-spool-capture não muda: spool, dispatch e consumo permanecem idênticos. O GC é passo novo pós-distill, coberto pela capability nova. -->

## Impact

- `scripts/distill-prompt.md`: contrato JSON (+`obsolete`), regras de título estável.
- `lib/parse-distill.py`: parse de `obsolete` → SQL de arquivamento; retenção de `state`.
- `scripts/distill.sh`: gate de GC pós-insert + dispatch do passo de consolidação.
- Novo script de GC (prompt próprio + worker) reutilizando o padrão detached existente.
- `lib/db.sh` / `scripts/db-init.sh`: migração de schema (`archived_at` em `memories`, tabela/colunas de bookkeeping de GC).
- `scripts/inject.sh`, `scripts/fts-recall.sh`, `scripts/brains-cli.sh`: filtrar `archived_at IS NULL`; subcomandos `gc`/`restore`.
- Caminho quente inalterado: SessionStart/Stop continuam SQL puro; todo custo de modelo roda no worker detached após a sessão terminar.
