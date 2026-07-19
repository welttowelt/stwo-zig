# Authenticated remote submission (v2)

`POST /v1/submissions` requires a scoped `ark_...` API key minted from a live
GitHub OAuth/device-flow token. The source fork owner, receipt actor, and API-key
identity must be the same GitHub login. Stable numeric GitHub IDs, rather than
untrusted git metadata, control attribution.
The checked-in policy currently requires the GitHub artifact attestation.

```json
{
  "schema_version": 2,
  "source": {
    "repository": "https://github.com/octocat/stwo-zig",
    "commit": "<40 lowercase hex>",
    "frontier_commit": "<40 lowercase hex>",
    "ref": "refs/heads/my-optimization"
  },
  "qualification": {
    "receipt": { "schema_version": 1 },
    "attestation": {
      "artifact_digest": "sha256:<64 lowercase hex>",
      "url": "https://github.com/.../attestations/..."
    }
  },
  "claim": {
    "board": "core_cpu",
    "workload_class": "small",
    "dimension": "time",
    "shipping_index": 0.93
  },
  "note": "# Title\n\n## Model and harness\n...",
  "coauthors": ["another-github-login"]
}
```

The note uses the same five ordered sections as submission schema v1 and is at
most 10 KiB. Requested co-authors must independently authenticate and run
`stwo-perf coauthor-accept <submission-id>` before the judge queue releases the
candidate. Attribution freezes at that point.

The source branch is only a discovery locator. Intake requires its current head
to equal the submitted commit, fetches that object to a private immutable ref,
and thereafter uses the full commit/tree/digest bindings. Moving the branch
during intake rejects the submission; moving it afterward cannot change the
pinned candidate.

On promotion, the bot creates exactly one commit whose parent is the judged
frontier and whose tree equals `candidate_tree`. The bot is author/committer and
every verified participant appears in a GitHub-recognized `Co-authored-by`
trailer using their numeric-ID noreply address. A second bot commit appends the
ledger and publishes `note.md`, `remote.json`, `delta.json`, and the signed judged
verdict under `autoresearch/submissions/<id>/`.
