# Build Architecture Authority Activation

Status: **fail closed**. The checked-in state at
`conformance/build-architecture-authority-state-v1.json` keeps BG-15 disabled.

## Required Controls

Do not set `bg15_release_authority_enabled` to `true` until all of the following
exist outside candidate control and their configuration evidence is archived:

1. A protected, environment-scoped full-hash variable or secret named
   `ARCHITECTURE_AUTHORITY_SHA` in `build-architecture-authority`. It must not
   be a repository-wide variable. It must identify the reviewed commit
   containing `.github/workflows/architecture-authority.yml`, the architecture
   plan, protocol, validators, and this activation state. It must differ from
   every candidate commit evaluated by that authority version.
2. A protected environment named `build-architecture-authority` that restricts
   dispatch and approval to the repository owner, prevents candidate workflows
   from reading or changing its configuration, and covers the `session`,
   `linux`, `macos`, and `verify` jobs.
3. A required check bound to the protected workflow identity and GitHub Actions
   app, with context `Build architecture authority / verify`. A status string
   emitted by `.github/workflows/ci.yml` is not an equivalent control.
4. Role-matching protected Linux and macOS runners. Each runner must execute the
   authority plan and Python policy from the authority checkout against a
   separate, exact, clean candidate checkout.
5. An external verifier or repository plan that can enforce those controls.
   The current private-repository plan returns `403` for the required ruleset,
   branch-protection, environment, and repository-variable APIs, so repository
   workflows alone cannot authorize BG-15.
6. OS-enforced separation between candidate execution and authority state. The
   candidate process must be unable to read or write the authority checkout,
   oracle bundles, session nonce, receipt roots, workflow credentials, or any
   protected configuration. A sibling directory with ordinary same-user file
   permissions is not isolation.
7. A minimal, explicit child environment. Candidate commands receive only the
   variables required by the build toolchain and the candidate checkout. GitHub
   tokens, `GH_*`, `GITHUB_*`, authority/session variables, bundle paths, and
   receipt paths must be absent.
8. Descendant containment. Each candidate command runs in a dedicated process
   group or stronger sandbox, and timeout/failure handling terminates and drains
   the complete descendant tree before validation continues.
9. Post-command authentication. After every candidate command, the controller
   must reauthenticate the authority commit and workflow bytes, oracle bundle
   bytes and modes, immutable inputs, output root ownership, and receipt root
   emptiness. Any mutation is an immediate NO-GO.

The activation change must link evidence for each control, include a successful
deliberate NO-GO mutation run, and be reviewed independently of the candidate it
will evaluate. Merely changing the JSON boolean is not activation evidence.

## Bundle Rotation

Run `.github/workflows/native-oracle.yml` from the pinned authority commit. Both
`Native oracle producer (linux)` and `Native oracle producer (macos)` must pass.
Record the producer run ID, attempt, artifact IDs, GitHub artifact SHA-256
digests, authority commit/tree, workflow-definition SHA-256, Rust toolchain, and
bundle content addresses. Architecture hosts consume the mode-preserving tar
artifacts and never invoke Cargo, rustc, or rustup.

Produce the exhaustive RISC-V anchor using the owner-dispatched producer in
`.github/workflows/ci.yml`. Record its run ID, attempt, artifact ID/digest,
candidate/tree, workflow identity, and release-policy receipt. Rotate either
bundle when its pinned sources, toolchain, authority workflow, or policy changes;
never silently rebuild it inside the architecture run.

## Candidate Run

Dispatch `.github/workflows/architecture-authority.yml` with exactly:

- `candidate_sha`: the full candidate commit;
- `riscv_producer_run_id`: the authenticated exhaustive RISC-V producer run;
- `native_oracle_run_id`: the authenticated two-host Native oracle producer run.

The session authenticates the authority and candidate as distinct clean
checkouts and issues one nonce. Linux and macOS independently execute the exact
authority plan against the candidate, then publish exact two-member artifacts:
`receipt.json` and `preimages.zip`. Preimages are bounded audit records, not a
substitute for execution. The aggregate job fetches both artifacts by ID and
outer digest, rejects mixed roles or runs, and writes a PASS only after both host
receipts validate under the same authority, candidate, tree, nonce, and plan.

The canonical aggregate result is:

`zig-out/release-evidence/build-architecture/<candidate_sha>/receipt.json`

Until the external controls above are installed and the activation state is
independently flipped, the aggregate entrypoint rejects issuance even when all
underlying correctness diagnostics pass.
