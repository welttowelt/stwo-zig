# Fork qualification receipt (v1)

A participant runs `autoresearch-qualify-fork` in their own GitHub fork. The
workflow performs the public benchmark and emits `qualification/receipt.json`.
Fork CI shifts routine compute to the participant's account; it is not a trust
root. Central intake recomputes every git-tree field and the judge independently
rebuilds, reruns the score, and draws a secret holdout.

The receipt binds:

- the full candidate and canonical-frontier commit IDs;
- the candidate tree ID, sorted changed paths, full-index binary patch digest,
  and locked-tree digest;
- six green qualification checks from `MANIFEST.json`;
- the GitHub actor, public aggregate score claim, and workflow provenance.

```json
{
  "schema_version": 1,
  "candidate_commit": "<40 lowercase hex>",
  "frontier_commit": "<40 lowercase hex>",
  "candidate_tree": "<40 lowercase hex>",
  "changed_paths": ["src/core/fields/example.zig"],
  "patch_digest": "sha256:<64 lowercase hex>",
  "locked_tree_digest": "sha256:<64 lowercase hex>",
  "submitter_login": "octocat",
  "checks": {
    "allowed_diff": true,
    "locked_tree": true,
    "source_modes": true,
    "harness_tests": true,
    "release_build": true,
    "public_benchmark": true
  },
  "claim": {
    "board": "core_cpu",
    "workload_class": "small",
    "dimension": "time",
    "shipping_index": 0.93
  },
  "workflow": {
    "repository": "octocat/stwo-zig",
    "workflow_ref": "...",
    "run_id": "...",
    "run_attempt": "1",
    "event": "workflow_dispatch",
    "runner_environment": "github-hosted"
  }
}
```

When artifact attestation is used, the attested subject is the exact pretty JSON
serialization emitted by `qualify_action.py`: keys sorted, two-space indentation,
and one final newline. Remote intake checks the supplied SHA-256 and runs
`gh attestation verify` against the fork repository.
Intake also requires the exact `.github/workflows/qualify-fork.yml` signer,
candidate source digest, submitted branch ref, GitHub OIDC issuer, and a
GitHub-hosted runner; a different workflow in the same fork is not sufficient.

Exact rejection rules are implemented by `stwo_perf.qualification`: the declared
frontier must be an ancestor, every changed path must match `editable_paths`, no
locked or stray path may change, final source modes must be `100644`, existing
modes may not change, and the locked-tree digest must remain identical.
