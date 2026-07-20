# Benchmark publication

`bench/` is the presentation boundary for committed stwo-zig performance
evidence. Raw reports, deltas, and proof bundles remain immutable under
`vectors/reports/benchmark_history/`; the site contains only a deterministic,
bounded projection of that archive.

## Layout

```text
bench/
├── README.md
└── site/
    ├── index.html            # Authored semantic shell
    ├── assets/
    │   ├── app.js            # Dependency-free presentation logic
    │   ├── responsive.css    # Narrow viewport adaptations
    │   └── styles.css        # Fixed-viewport dark interface
    └── data/
        └── catalog.json      # Generated, reviewable publication catalog
```

## Evidence contract

A run is publishable only when it carries all of the following:

- a 40-character clean measurement commit;
- an offset-aware ISO-8601 capture time;
- complete machine, OS, GPU, and toolchain identity;
- CPU/SIMD and Metal proof parity for every row;
- successful verification by the pinned Rust Stwo oracle;
- content hashes that agree with the immutable history index.

Historical runs that predate this contract remain in the archive. The catalog
records them under `excluded_runs` with explicit reasons and never upgrades them
into formal performance evidence.

The measurement commit is distinct from the commit that deploys the site.
Publishing a benchmark never rewrites its source identity.

## Commands

```sh
python3 scripts/benchmark_pages.py
python3 scripts/benchmark_pages.py --validate
python3 -m http.server 8000 --directory bench/site
```

The first command regenerates only `site/data/catalog.json`. HTML, CSS, and
JavaScript are authored assets and are validated separately. GitHub Pages
publishes on relevant `main` updates and checks nightly for new benchmark or
site commits.
