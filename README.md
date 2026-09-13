# conversation-protocol

Lispy **CLOS** conversation memory for [cl-stack](https://github.com/egao1980/cl-stack) — session store + buffer / window / token-window. Turns stay [`llm-turn`](https://github.com/egao1980/llm-protocol).

**Not** RAG. **Not** GFs on `llm-protocol`. SQL persist is [`conversation-backend-sql`](https://github.com/egao1980/conversation-backend-sql).

| System | Role | Repo |
|--------|------|------|
| `conversation-protocol` (`stack-conversation`) | Protocol + in-process store + buffer / window / token-window | this repo |
| `conversation-protocol/summary` | `summary-memory` (calls `llm-protocol:generate`) | this repo |

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

Wire an agent by hand:

```lisp
(run-ai-agent agent (recall mem incoming :session "s1"))
(remember mem (agent-run-turns run) :session "s1" :replace t)
```

Or wait for `ai-agent-protocol` `:memory` (optional slot; `prepare-agent-turns` + finish).

Missing store/memory → `conversation-missing-backend` (`use-value`). Missing `delete-session` → `conversation-session-not-found` (`continue`). Summary without an LLM backend signals `conversation-missing-backend` (`:role :backend`).

## License

MIT
