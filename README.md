# conversation-protocol

Lispy **CLOS** conversation memory for [cl-stack](https://github.com/egao1980/cl-stack) — session store + buffer / window / token-window. Turns stay [`llm-turn`](https://github.com/egao1980/llm-protocol).

**Not** RAG. **Not** GFs on `llm-protocol`. SQL persist is [`conversation-backend-sql`](https://github.com/egao1980/conversation-backend-sql).

| System | Role | Repo |
|--------|------|------|
| `conversation-protocol` (`stack-conversation`) | Protocol + in-process store + buffer / window / token-window | this repo |
| `conversation-protocol/summary` | `summary-memory` (calls `llm-protocol:generate`), `provider-compaction-memory` (`llm-protocol:server-compact`) | this repo |

```lisp
(asdf:load-system "conversation-protocol")

(let ((mem (stack-conversation:make-window-memory :window-size 6 :session "chat-1")))
  (stack-conversation:remember mem
                               (list (stack-llm:user-turn "hi")
                                     (stack-llm:assistant-turn "hello")))
  (stack-conversation:recall mem "again" :session "chat-1"))
```

| Role | GF | In-tree |
|------|----|---------|
| `conversation-store` | `load-session` / `save-session` / `delete-session` | `in-memory-conversation-store` |
| `conversation-memory` | `recall` / `remember` / `clear-memory` | `buffer-memory` (all), `window-memory` (last N non-system + all `:system`), `token-window-memory` (`fit-turns` / `count-tokens`) |

`recall` = stored history + incoming (incoming is not persisted). `remember` appends; `:replace t` snapshots.

- **Window** is **turn count**, not tokens.
- **Token window** uses `llm-protocol:count-tokens` + `fit-turns` (`token-fit-policy` from `:max-tokens` / `:reserve`). Optional `:backend` is only for counting; a dummy `llm-backend` is used when none is bound so generate is not required.

## Summary memory

Load `conversation-protocol/summary` (core does not call `generate`). When the non-system turn count exceeds `:window-size` **or** `count-tokens` exceeds `:max-tokens` (minus `:reserve`), the oldest overflow span is compressed via `llm-protocol:generate` into **one `:system` turn whose text starts with `[summary]`** (not a dedicated role). Previous `[summary]` turns are folded into the next compression. Real `:system` turns are kept.

```lisp
(asdf:load-system "conversation-protocol/summary")

(let ((mem (stack-conversation:make-summary-memory
            :window-size 6
            :backend (stack-llm:make-mock-llm-backend))))
  (stack-conversation:remember mem
                               (list (stack-llm:user-turn "u1")
                                     (stack-llm:assistant-turn "a1"))))
```

### Compaction

`(compact-turns memory turns &key backend)` → `(values new-turns compacted-p)` shrinks TURNS **now**, whatever the memory's usual limits say. An agent calls it when the prompt overflows the context window or crosses a token threshold. The base memory compacts nothing. `summary-memory`:

- keeps real `:system` turns and the newest `:tail-tokens` (default 15000, at least the last turn) verbatim;
- never opens the kept tail on a `:tool` result whose call would be summarized away (the window policy follows the same rule);
- summarizes the rest, earlier `[summary]` turns included, from a plain-text `render-transcript` (tool arguments and results clipped to `*summary-part-chars*`). Plain text means no provider can reject a dangling tool call.

The default prompt is `+compaction-prompt+`, a fixed template with the headings Objective / Requirements / Decisions / Work State / Next Move / Relevant Files / Important Context, so every compaction keeps the same kinds of facts. `:prompt` replaces it.

This is agent-side compaction. Providers can also compact on their side:

`provider-compaction-memory` (`make-provider-compaction-memory :backend b :instructions s :tools ts :fallback mem`): `compact-turns` calls `llm-protocol:server-compact` (Anthropic compaction on demand). The result is the system turns plus the provider's summary part; other backends read it as text (`llm-protocol:portable-turns`). No summary from the provider → NIL, compact later. A backend without `:compaction` uses `:fallback` (e.g. a `summary-memory`) on the portable turns; with no fallback it signals `llm-unsupported` (`use-value` gives new turns). Threshold compaction stays the backend's option (llm-protocol-anthropic `:server-compaction`).

Wire an agent by hand:

```lisp
(run-ai-agent agent (recall mem incoming :session "s1"))
(remember mem (agent-run-turns run) :session "s1" :replace t)
```

Or wait for `ai-agent-protocol` `:memory` (optional slot; `prepare-agent-turns` + finish).

Missing store/memory → `conversation-missing-backend` (`use-value`). Missing `delete-session` → `conversation-session-not-found` (`continue`). Summary without an LLM backend signals `conversation-missing-backend` (`:role :backend`).

## License

MIT
