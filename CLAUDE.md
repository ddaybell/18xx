@AI_CONTEXT.md

## Claude-Specific Instructions

### AGENTS.md sync rule
Whenever you modify `AI_CONTEXT.md`, you MUST also update `AGENTS.md` to match.
`AGENTS.md` is the Codex/OpenAI version of the same context — it cannot use `@imports`, so it must
always be kept as a verbatim copy of `AI_CONTEXT.md`. After any edit to `AI_CONTEXT.md`, immediately
apply the same changes to `AGENTS.md`.
