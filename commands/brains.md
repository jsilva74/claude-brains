---
description: Inspect and manage claude-brains memory (status, search, list, forget, learn, stats, update)
argument-hint: "[status|search <q>|list|forget <title>|summaries|projects|stats|learn|update]"
allowed-tools: Bash(bash:*)
---

Run the claude-brains management CLI and show the user the result.

Execute exactly this, passing the user's arguments through verbatim:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/brains-cli.sh" $ARGUMENTS`

Then briefly summarize the output for the user. If `$ARGUMENTS` is empty, the CLI
defaults to `status` for the current project. Do not invent memory contents —
only report what the command prints.
