# occt-build

Prebuilt [Open CASCADE Technology](https://dev.opencascade.org/) (OCCT) archives for [eidom](https://github.com/TimothyBesada/eidom), a parametric CAD application whose kernel sits behind a Rust trait.

eidom pins OCCT 8.0.1 at an exact commit and builds it outside Cargo with OCCT's own CMake (eidom D-013). This repository holds that build: the script, a GitHub Actions matrix for the two PoC targets (macOS arm64, Linux x64), and releases with the archives, `SHA256SUMS`, OCCT's source tarball, the build script, and the LGPL and exception texts. Each install prefix carries a `manifest.json` (OCCT version and commit, compiler, flags, config hash) that eidom folds into its build fingerprint (eidom D-032). eidom's `just occt` downloads and verifies the pinned archive.

The repository is public so that the archives download without credentials, and so that its releases serve as OCCT's LGPL source offer.

Status: empty until eidom's M0 task builds it. The decisions live in eidom's [`docs/decisions.md`](https://github.com/TimothyBesada/eidom/blob/main/docs/decisions.md) (D-013, D-017, D-032); the task is in its [`docs/poc-plan.md`](https://github.com/TimothyBesada/eidom/blob/main/docs/poc-plan.md).

Work here follows eidom's conventions ([`docs/agents/issue-tracker.md`](https://github.com/TimothyBesada/eidom/blob/main/docs/agents/issue-tracker.md)): one branch per Linear issue, PRs titled `CAD-n: …`, merged into `main` with a merge commit.
