# Easier Waypoints

**One road. One direction. No guesswork.**

A Transport Fever 3 mod that shows where a waypoint will go before you place it:
the lane, its direction of travel and the part of the line you are editing. It
works for road, tram, rail, ship and air lines.

## Status

Version **0.2.0**, game revision **2**. **Experimental:** not yet verified in-game.

## Features

- An **Add Waypoint** button above the stop list while you edit a line. Its tooltip
  says which part of the line new waypoints go into.
- The placement tool highlights the lane under the cursor (red where the line's
  vehicles can't go) and shows the direction of travel before you click. Each click
  adds the next waypoint in order. Right-click or press Esc to finish.
- Click the line's route to add a waypoint to that part of the line. Move across
  the road to choose the side; the highlight and arrow follow.
- Arrows are only shown when the road's own lane data confirms the direction.
  Tracks are shown as usable both ways, because the route decides.
- Ships and aircraft get a point marker, with the game's own water and spacing
  checks.
- Holding the game's waypoint key and clicking still works; the tooltips explain it.
- The game's own Line Manager saves every change. No custom save data.

| Line type | Waypoint | What is shown |
|---|---|---|
| Road, tram | Lane | Lane highlight, travel arrow, stretch |
| Rail | Track | Track highlight, both-way arrows, stretch |
| Ship, aircraft | Point | Marker, water and spacing feedback, stretch |

Other mods that replace the Line Manager's waypoint tooltips or stop panel may
conflict with this one.

## Trying it locally

Build the ZIP with `python3 scripts/package_release.py`. Back up the save you test
with. Open the game's user-data folder from Settings → Advanced, then put the
`easier_waypoints_1` folder from the ZIP into its development `staging_area`.
Restart the game and enable Easier Waypoints. In the Line Manager, select a line,
then the stretch to edit, and press **Add Waypoint**.

## Development checks

```sh
lua5.4 tests/direction_test.lua
lua5.4 tests/ui_contract_test.lua
luajit tests/direction_test.lua
luajit tests/ui_contract_test.lua
python3 -m unittest discover -s tests -p '*_test.py'
python3 scripts/package_release.py
```

To also run the UI test against the game's React registry, set `TF3_REACT_LUA` to
your own game's `gui/main/react.lua` extracted from `base/content/gui.zip`. Game
source is not included in this repository or its packages. Offline checks do not
cover in-game behaviour.

## Versioning and release tooling

Adapted from [Subsidy Manager](https://github.com/Ashcutus/Transport-Fever-3-Subsidy-Tracker):

- `VERSION` holds the public `MAJOR.MINOR.PATCH` label. `mod.json` has a separate
  integer `revision`; increment it when changing shipped files, including metadata.
  Tooling-only changes do not require a game revision bump.
- Update the visible Changes section in `_metadata/modinfo.json` for each release.
- `scripts/package_release.py` builds a deterministic runtime-only ZIP and SHA-256
  checksum. It never uploads or publishes anything.
- Start each in-game upload changelog with `vMAJOR.MINOR.PATCH`, for example
  `v0.2.0 — Experimental placement tool for every line type`.
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
