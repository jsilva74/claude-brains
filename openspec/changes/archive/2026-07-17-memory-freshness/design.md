# memory-freshness — design

## Context

O pipeline atual (spool → distill worker detached → SQLite) só cresce o corpus: upsert por `(project_id, title)` é o único mecanismo de atualização, e ele falha quando o título muda (versões/datas embutidas) ou quando o fato simplesmente deixa de ser verdade (`state` resolvido). O dedup guidance do distill vê apenas os 40 títulos mais recentes — menor que o corpus de projetos ativos (sif: 295) — então duplicação semântica passa invisível. Resultado observado: memórias contraditórias injetadas juntas na mesma sessão.

Restrições:
- Caminho quente intocável: SessionStart/UserPromptSubmit/Stop são SQL puro (µs). Nenhum call de modelo pode entrar neles.
- Todo custo de modelo já roda no worker detached de `distill.sh`, depois que a sessão morreu. Novas camadas devem pegar carona nesse padrão.
- Decisão de modelo barato (haiku) nunca pode causar perda irreversível de dados.
- Portabilidade macOS/Linux, bash + sqlite3 + jq + python3 (dependências já existentes; nada novo).

## Goals / Non-Goals

**Goals:**
- Memórias invalidadas por uma sessão saem de circulação no mesmo distill dessa sessão, sem call extra.
- Títulos estáveis: upsert volta a colidir corretamente.
- `state` velho some sozinho (SQL puro).
- Corpus consolidado automaticamente quando acumula — sem depender de comando manual.
- Toda remoção decidida por modelo é reversível por 30 dias.

**Non-Goals:**
- Busca semântica/embeddings (FTS5 continua sendo o mecanismo de recall).
- GC de `summaries` (só a mais recente é injetada; acúmulo é inofensivo).
- GC cross-project (cada projeto é consolidado isoladamente).
- Verificação de memórias no momento da recall (custo proibitivo no caminho quente).

## Decisions

### D1 — Soft-delete via `archived_at`, nunca DELETE por decisão de modelo

`ALTER TABLE memories ADD COLUMN archived_at TEXT` (NULL = ativa). Arquivada sai imediatamente de inject/FTS-recall/dedup-guidance; purge física (DELETE) só após 30 dias, executada como SQL barato no pós-distill. `/brains restore <title>` zera `archived_at`.

- *Alternativa rejeitada:* DELETE direto — haiku errando = perda irreversível.
- *Alternativa rejeitada:* tabela `memories_archive` separada — duplica schema, complica FTS e restore; uma coluna resolve.
- FTS: triggers permanecem intactos; o filtro `m.archived_at IS NULL` entra nas queries que fazem JOIN com `memories` (inject, fts-recall, cli search/list/status). Arquivadas continuam indexadas mas nunca retornadas — e ficam acháveis por `brains archived`/`restore`.
- Migração: `brains_ensure_db` ganha passo idempotente — checa `pragma_table_info('memories')` e aplica o ALTER se a coluna falta. Compatível com o padrão atual de re-apply de schema.

### D2 — Reconciliação no distill: campo `obsolete` no contrato JSON

`distill-prompt.md` passa a aceitar `"obsolete": ["title", ...]` — títulos da lista "Existing memories" que a sessão comprovadamente invalidou (trabalho concluído, decisão revertida, fato substituído). `parse-distill.py` emite `UPDATE memories SET archived_at=datetime('now') WHERE project_id=? AND title IN (...)`.

- Custo: zero calls extras — mesmo call, ~+50 tokens de contrato.
- Escopo natural: o modelo só pode arquivar títulos que viu (janela de 40) — exatamente os mais recentes, onde staleness dói.
- Prompt conservador: "só marque obsolete com evidência explícita no transcript; na dúvida, não marque".
- UPDATE com título inexistente = no-op inofensivo.

### D3 — Higiene de títulos no prompt

Regra nova no `distill-prompt.md`: título é chave de identidade estável — **nunca** embutir versão, data ou status (`foo_v1.2.1_live` → `foo_release_status`). O que muda vai no `body`. Ataca a raiz do caso observado (v1.2.1/v1.2.2 coexistindo).

### D4 — Retenção de `state`: só os K mais recentes ativos (K=5)

Pós-insert no distill worker, SQL puro arquiva `state` além dos 5 mais recentes do projeto:

```sql
UPDATE memories SET archived_at=datetime('now')
WHERE project_id=:pid AND type='state' AND archived_at IS NULL
  AND id NOT IN (SELECT id FROM memories
                 WHERE project_id=:pid AND type='state' AND archived_at IS NULL
                 ORDER BY updated_at DESC LIMIT 5);
```

- *Alternativa rejeitada:* TTL por idade — projeto parado 60 dias perderia o "where we left off", exatamente quando mais precisa.
- K=5 configurável via `BRAINS_STATE_KEEP`.

### D5 — GC automático gated, piggyback no worker detached

Após distill bem-sucedido, `distill.sh` avalia gate barato (1 SELECT + leitura da tabela `meta`):

```
dispara GC ⟺ distills_since_gc ≥ 5
            E (active_count > BRAINS_GC_THRESHOLD (120)
               OU distills_since_gc ≥ 25)
```

- O `E distills_since_gc ≥ 5` evita GC-storm: projeto legitimamente grande (count fica >120 mesmo após GC) não dispara a cada sessão.
- Bookkeeping na tabela `meta` existente: chaves `gc_last_at:<pid>` e `gc_distill_count:<pid>` — sem schema novo.
- Sessão nunca espera: gate e GC rodam no worker que já é detached; latência percebida = zero.
- *Alternativa rejeitada:* GC manual (`/brains gc` como único caminho) — usuário não roda, lixo acumula (motivo desta change).
- *Alternativa rejeitada:* hook/cron separado — mais superfície, mesmo efeito; o pós-distill é o momento natural (corpus acabou de mudar).

### D6 — GC = segundo call haiku, isolado, input bounded, saída conservadora

Novo `scripts/gc.sh` + `scripts/gc-prompt.md`, mesmo padrão de isolamento do distill (`--setting-sources ''`, system prompt JSON-only, haiku, `CLAUDE_BRAINS_DISTILLING=1` como guarda de recursão).

- **Input:** fatia de até 80 memórias ativas (cap 32k chars), mais antigas primeiro — onde o lixo mora. Projeto gigante → uma fatia por trigger (GC incremental); nunca um call monstro.
- **Contrato de saída:**
  ```json
  {
    "archive": ["title", ...],
    "update":  [{ "title": "...", "type": "...", "body": "corpo consolidado" }]
  }
  ```
  `archive` = obsoletas/duplicadas superadas; `update` = memória canônica reescrita absorvendo as duplicatas arquivadas. Parser (`lib/parse-gc.py`, reutilizando helpers de `parse-distill.py`) valida tipos/limites e emite UPDATEs — nunca INSERT (GC não inventa memória nova) e nunca DELETE.
- **Lock:** `mkdir` atômico em `~/.claude/brains/state/gc.lock/` com steal por mtime > 10 min. Multi-sessão simultânea não roda GC duplo.
- **Falha do call/parse:** exit 0 silencioso, bookkeeping não avança → retry natural no próximo gate.

### D7 — CLI: `gc`, `archived`, `restore`; `forget` vira soft

- `brains gc [path]` — força GC agora (ignora gate, respeita lock). Override manual, não caminho principal.
- `brains archived [path]` — lista arquivadas (título + quando).
- `brains restore <title>` — `archived_at=NULL`.
- `forget` passa de DELETE para arquivamento — consistente com a filosofia de recuperabilidade; purge de 30d apaga de vez.

## Fluxo resultante

```
Stop ──► spool (µs, inalterado)
SessionEnd/PreCompact ──► launcher ──► worker detached:
  1. distill call (haiku)  ──► upsert memories + summary
  2. parse `obsolete`      ──► archive títulos invalidados      (D2)
  3. retenção state K=5    ──► SQL puro                          (D4)
  4. purge archived >30d   ──► SQL puro                          (D1)
  5. gate GC (1 SELECT)    ──► se disparado: gc.sh               (D5)
        └─► call haiku bounded ──► archive/update consolidação   (D6)
SessionStart / UserPromptSubmit ──► inject/recall filtram archived_at IS NULL (µs)
```

## Risks / Trade-offs

- [Haiku arquiva memória válida] → soft-delete + 30d de janela + `restore`; prompts conservadores ("na dúvida, mantenha"); GC nunca deleta, só arquiva/reescreve.
- [GC-storm em projeto grande] → gate composto com mínimo de 5 distills entre GCs.
- [Dois workers disparam GC simultâneo] → lock `mkdir` atômico; perdedor sai silencioso.
- [Lock órfão trava GC pra sempre] → steal por mtime > 10 min.
- [Fatia de 80 nunca alcança o corpus todo] → fatias são "mais antigas primeiro" e cada GC avança; corpus 295 → ~4 triggers para cobertura completa; aceitável para manutenção de fundo.
- [`update` do GC reescreve body e perde nuance] → prompt exige preservar informação factual; original recuperável? Não (UPDATE in-place) — trade-off aceito: body é 1-3 frases, risco baixo; alternativa (versionar bodies) = complexidade desproporcional.
- [Coluna nova quebra queries antigas de versões instaladas mistas] → ALTER só adiciona coluna nullable; scripts antigos ignoram-na sem erro.

## Migration Plan

1. `brains_ensure_db` aplica ALTER idempotente (checagem via `pragma_table_info`).
2. Nenhuma transformação de dados existente: tudo nasce ativo (`archived_at NULL`).
3. Primeira rodada de GC nos projetos grandes limpa o passivo acumulado gradualmente (fatias).
4. Rollback: coluna e chaves `meta` são inertes para versões antigas do plugin; basta voltar a versão.

## Open Questions

(nenhuma — defaults escolhidos: K=5 states, threshold 120, mínimo 5 / máximo 25 distills, fatia 80/32k, purge 30d; todos tunáveis por env `BRAINS_*`)
