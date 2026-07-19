# Remote queue and promotion state machine

```text
received -> validating -> awaiting_coauthors -> queued -> judging
                  |                |                         |
                  |                +---- all accept ---------+
                  |                                          |
                  +-> rejected                +---------------+-------------+
                                               |               |             |
                                            neutral         rejected     promotable
                                                                            |
                                                                         promoting
                                                                            |
                                                            stale <- frontier check -> promoted
                                                                            |
                                                                    promotion_error
```

`withdrawn` is available to the primary author before judging. `stale` means the
canonical repository moved after qualification or judgment; it is terminal and
the participant should sync, rerun fork CI, and submit a new commit. Only one
active submission per GitHub identity is admitted by default, and a source
commit can never be submitted twice.

The store is an atomic, mode-0600 JSON file protected by a process/thread lock.
The HTTP process never checks out, builds, or executes participant code.
`backend/worker.py` is the only component that consumes the queue:

1. intake fetches and recomputes cheap source evidence;
2. the controlled Apple runner canonicalizes and judges against the exact HEAD;
3. the signed verdict becomes `promotable`, `neutral`, or `rejected`;
4. promotion re-verifies signature, parent, tree, frontier, and clean checkout;
5. a failed network push remains `promoting` with an immutable promotion commit
   and is safely retried; ambiguous partial repository work becomes
   `promotion_error` and is never reset automatically.

The externally visible reward is deliberately small: one shipping index for the
declared board/class/dimension plus gate and secret-holdout pass/fail. Detailed
workloads remain judge evidence, not dozens of individually optimizable public
leaderboards.
