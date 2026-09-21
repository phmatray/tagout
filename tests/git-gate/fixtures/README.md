# Captured `PreToolUse` payloads

Two payloads a real Claude Code session handed a `PreToolUse` hook, recorded rather than written.

`hooks/git-write-gate.sh` decides whether to honour a `GIT_GATE=off` prefix by reading `agent_id`
from that payload (#643, #646): present means a sub-agent, whom nobody is there to approve a bypass
for. The rest of `tests/git-gate/test.sh` drives synthesised payloads, which is the right seam for
forty cases — but a synthesised payload agrees with whatever the suite believes the field is called.
Nothing in the repository said what the host actually sends, so a host that renamed or nested
`agent_id` would turn the fix back off with every case still green (#652).

## How they were captured

A `PreToolUse` hook on matcher `Bash` that does nothing but `cat >>` its stdin and `exit 0`,
registered through `claude -p --settings <file>` so it is loaded at session start:

```sh
claude -p --settings ./settings.json --permission-mode bypassPermissions \
  "Dispatch exactly one general-purpose subagent with the Agent tool. Its only instruction: run
   the Bash command 'echo hello-from-subagent' and report the output. Do not run any Bash
   yourself."
```

and the same again without the dispatch, for the main-thread half.

- **Captured:** 2026-09-21, Claude Code 2.1.278, macOS.
- `pretooluse-subagent.json` — the sub-agent's own `Bash` call. Carries `agent_id` **at the top
  level**, a string, beside an `agent_type`.
- `pretooluse-main-thread.json` — the same call made by the main thread. Carries **neither**.

## What was edited, and what was not

Every KEY and every value SHAPE is exactly as captured. Replaced, because they are one machine's:
`cwd`, `transcript_path`, `session_id`, `prompt_id`, `tool_use_id`, the `agent_id` digits, and
`tool_input` (the suite substitutes the command under test into it anyway). Nothing was added, and
no key was removed — an absent `agent_id` in the main-thread payload is the fixture's whole point.

Re-capture these, do not hand-edit them, when a host's payload is suspected of having changed.
