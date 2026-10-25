# Easier Waypoints

- Keep investigations, extracted game source, logs and disposable saves under
  `.local/`, ignored by git. Do not publish game source or private investigations.
- Use supported TF3 APIs. Do not introduce fragile runtime patches without explicit
  operator approval. Current UI integrations use `react-replacement-config`.
- Preserve native routing and editing. Do not issue simulation commands while
  hovering or cancelling. Do not claim pathfinding equivalence from network search.
- `VERSION` is the public semantic version. `mod/easier_waypoints_1/mod.json` uses
  an independent integer `revision`. Bump that revision exactly once for a PR that
  changes shipped mod files, including metadata; tooling-only PRs do not bump it.
- Update the visible Changes history in `_metadata/modinfo.json` for each release.
  Do not add an unsupported `version` field to the game metadata.
- Keep packaging and mod.io label tooling aligned with Subsidy Manager's behavior.
  Use only Easier Waypoints' explicitly configured mod.io listing. Never copy tokens
  or listing IDs from another project. Label scripts must remain preview-first.
- Run the Lua geometry and UI contract tests, Python release tests and reproducible
  packaging check. Report untested in-game behavior separately from offline checks.
- No automatic deployment, uploads, releases or mod.io writes without authorization.
