# memory-freshness — tasks

## 1. Schema e soft-delete (D1)

- [x] 1.1 Adicionar migração idempotente em `lib/db.sh` (`brains_ensure_db`): coluna `archived_at TEXT` em `memories` via checagem `pragma_table_info`
- [x] 1.2 Filtrar `archived_at IS NULL` em `scripts/inject.sh` (memórias injetadas no SessionStart)
- [x] 1.3 Filtrar `archived_at IS NULL` em `scripts/fts-recall.sh` (JOIN do FTS)
- [x] 1.4 Filtrar `archived_at IS NULL` em `scripts/brains-cli.sh` (`status`, `search`, `list`, contagens) e na lista de dedup de `scripts/distill.sh` (existing memories)
- [x] 1.5 Adicionar purge físico de arquivadas > 30 dias no pós-distill (`distill.sh`, SQL puro)
- [x] 1.6 Verificar: criar DB com schema antigo, rodar `brains_ensure_db`, confirmar coluna adicionada e memórias intactas

## 2. Reconciliação e higiene no distill (D2, D3, D4)

- [x] 2.1 Estender `scripts/distill-prompt.md`: campo `obsolete` no contrato JSON + regra conservadora ("só com evidência explícita")
- [x] 2.2 Adicionar regra de título estável em `scripts/distill-prompt.md` (sem versão/data/status no título)
- [x] 2.3 Estender `lib/parse-distill.py`: parse de `obsolete` → UPDATEs de arquivamento restritos ao `project_id`
- [x] 2.4 Adicionar retenção de `state` (K=5, env `BRAINS_STATE_KEEP`) como SQL pós-insert em `distill.sh`
- [x] 2.5 Verificar: distill de transcript de teste que conclui um trabalho → memória `state` correspondente arquivada; 6º state → mais antigo arquivado

## 3. GC automático (D5, D6)

- [x] 3.1 Criar `scripts/gc-prompt.md`: contrato `{"archive": [...], "update": [...]}`, postura conservadora, preservar informação factual
- [x] 3.2 Criar `lib/parse-gc.py`: valida saída, emite apenas UPDATEs (archive + reescrita), nunca INSERT/DELETE
- [x] 3.3 Criar `scripts/gc.sh`: lock `mkdir` (steal por mtime > 10 min), fatia bounded (80 memórias / 32k chars, mais antigas primeiro), call haiku isolado (padrão do distill), bookkeeping em `meta` (`gc_last_at:<pid>`, `gc_distill_count:<pid>`)
- [x] 3.4 Integrar gate em `distill.sh` pós-insert: incrementar contador, avaliar `distills_since_gc >= 5 && (count > BRAINS_GC_THRESHOLD || distills_since_gc >= 25)`, disparar `gc.sh`
- [x] 3.5 Verificar: projeto de teste com >120 memórias e contador ≥5 → GC roda, arquiva/consolida, bookkeeping avança; call falho → DB intocado, bookkeeping parado; lock presente → segundo GC sai silencioso

## 4. CLI (D7)

- [x] 4.1 `brains-cli.sh gc [path]`: força GC (ignora gate, respeita lock), saída legível
- [x] 4.2 `brains-cli.sh archived [path]`: lista arquivadas com data
- [x] 4.3 `brains-cli.sh restore <title>`: `archived_at=NULL`
- [x] 4.4 Converter `forget` de DELETE para arquivamento
- [x] 4.5 Atualizar help do CLI e `commands/` (slash command `/brains`) com os novos subcomandos

## 5. Validação E2E e release

- [x] 5.1 E2E: sessão real → distill com `obsolete` → memória arquivada some do inject da sessão seguinte
- [x] 5.2 E2E: rodar `brains gc` manual num projeto grande real (ex. sif) e revisar qualidade das consolidações antes de confiar no automático
- [x] 5.3 Rodar shellcheck nos scripts alterados/novos; ruff nos .py
- [x] 5.4 Atualizar README (seção de manutenção automática) e sincronizar VERSION + plugin.json + docs (gotcha de release: manter manifests em sync)
