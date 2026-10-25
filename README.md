# Easier Waypoints

**One road. One direction. No guesswork.**

An experimental Transport Fever 3 UI mod that makes the selected road lane and
its travel direction visible before a waypoint is placed or moved.

## Prototype status

Version **0.1.0**, game revision **1**. Offline checks cover geometry, cyclic stop
sequences, UI delegation and release tooling. **In-game rendering, save/load and
stable-branch compatibility have not been verified.** The inspected installation
was Linux Steam preview build 26129055. This is a prototype, not a finished mod.

- Cyan highlights the candidate lane; white arrows show its direction.
- An edge reported as bidirectional gets arrows both ways.
- The stop panel names the selected stretch between stops.
- Unsupported or stale candidate data keeps the game's original feedback.
- Native controls still place, move and remove waypoints. No simulation commands,
  custom save data, automatic route correction or background line updates.

The prototype uses TF3's `react-replacement-config`, `ReplaceRecipe` and
`CallOriginalRecipe` APIs. It replaces three small tooltip recipes and wraps the
stop panel; it does not replace the Line Manager implementation or monkey-patch
module functions. Other UI mods targeting these same recipes can conflict.

## Trying it locally

Build the ZIP with `python3 scripts/package_release.py`. Use a disposable save.
Open the game's user-data folder from Settings → Advanced, then put the
`easier_waypoints_1` folder from the ZIP into its development `staging_area`.
Restart the game, enable Easier Waypoints, and select a road line in Line Manager.
Select the stretch to edit and use the game's displayed Add Waypoint action.
Hover over both sides of a road before clicking. Move/remove existing waypoints
with the normal native controls. There is no standalone placement button yet.

First check that the highlight and arrows appear before clicking, follow a curve
and slope, and disappear when leaving placement. Check that hover/cancel does not
edit the line. Bridges, tunnels, junctions, one-way roads and UI scaling need
in-game verification. Unsupported junction-only networks deliberately fall back
to native feedback. Reachability and full proposed routes are not predicted.

## Development checks

```sh
lua5.4 tests/direction_test.lua
lua5.4 tests/ui_contract_test.lua
python3 -m unittest discover -s tests -p '*_test.py'
python3 scripts/package_release.py
```

The UI contract test uses test doubles for native engine objects. To additionally
exercise the shipped Lua React registry, set `TF3_REACT_LUA` to your own game's
`gui/main/react.lua` extracted from `base/content/gui.zip`. Game source is not
included in this repository or its packages. Offline checks do not validate the
native C++ renderer or mod loader.

## Versioning and release tooling

Adapted from [Subsidy Manager](https://github.com/Ashcutus/Transport-Fever-3-Subsidy-Tracker):

- `VERSION` holds the public `MAJOR.MINOR.PATCH` label. `mod.json` has a separate
  integer `revision`; increment it when changing shipped files, including metadata.
  Tooling-only changes do not require a game revision bump.
- Update the visible Changes section in `_metadata/modinfo.json` for each release.
- `scripts/package_release.py` builds a deterministic runtime-only ZIP and SHA-256
  checksum. It never uploads or publishes anything.
- Start each in-game upload changelog with `vMAJOR.MINOR.PATCH`, for example
  `v0.1.0 — Experimental direction preview`.
- `scripts/set_modio_version.py` preserves Subsidy Manager's preview-first/manual
  confirmation, HTML changelog matching, file-ID validation, conflict protection,
  rechecks and post-write verification. It changes version labels only.

Easier Waypoints has **no configured mod.io listing yet**. `release.json` leaves
`modio_mod_id` null. The label script refuses to make any request until you supply
this mod's own ID there or through `MODIO_MOD_ID`. No Subsidy Manager listing ID,
token or publishing identity is carried across.

After creating this mod's listing yourself, configure the GitHub repository
variable `MODIO_MOD_ID` and repository secret `MODIO_ACCESS_TOKEN`. The copied
hourly/manual label workflow skips its job until the ID variable exists. The
workflow has not been run on GitHub and this project has not been uploaded.

```sh
python3 scripts/set_modio_version.py --list
python3 scripts/set_modio_version.py --sync
python3 scripts/set_modio_version.py --sync --apply
```

Python tooling uses only the standard library; Lua runtime code adds no external
dependencies. The workflow uses the same commit-pinned checkout action as the
source project. See `LICENSE` for the retained release-tooling attribution.
