# Easier Waypoints

**One road. One direction. No guesswork.**

An experimental Transport Fever 3 UI mod that shows where a waypoint will go
before it is placed: the lane, its direction of travel and the stretch of the line
being edited. It covers road, tram, rail, ship and air lines.

## Status

Version **0.2.0**, game revision **2**. Offline checks cover lane geometry, the
direction cross-check, stretch resolution, UI delegation, the placement tool, Lua
5.2 compatibility and release tooling. **Nothing has been verified in-game yet.**
Code was checked against Linux Steam preview build 26129055. Treat this as a test
build.

- **Place Waypoint** in the stop panel opens a placement tool on top of the Line
  Manager. It highlights the lane under the cursor (cyan, or red where the line's
  vehicles can't go), draws the direction of travel, and names the stretch. Each
  click adds the next waypoint in order; Back finishes. No modifier key is needed.
- The native flow still works. Its tooltips now say that the precision-mode key
  (shown as a key hint) must be held while clicking, and they explain direction.
- Arrows only appear when the lanes at that spot agree with the street's own lane
  config. Otherwise the lane is highlighted without an arrow and the tooltip says
  the direction couldn't be confirmed. Tracks are shown as usable both ways.
- Ships and aircraft get a point marker. Water-on-land and too-close checks match
  the game's own rules.
- The stop panel shows the stretch the game will really edit. This includes the
  "no stretch selected" case, where native `addWaypoint` inserts before the last
  entry rather than appending.
- Every change is committed by the Line Manager's own `addWaypoint`. Hovering and
  cancelling never edit the line. No custom save data, automatic route correction
  or background line updates.

| Line type | Waypoint | What is shown |
|---|---|---|
| Road, tram | Lane snap | Lane highlight, confirmed travel arrow, stretch |
| Rail | Track snap | Track highlight, both-way arrows (the route decides), stretch |
| Ship, aircraft | Point | Marker, water/too-close feedback, stretch |

The mod uses TF3's `react-replacement-config`, `ReplaceRecipe` and
`CallOriginalRecipe` APIs to replace three small tooltip recipes and wrap the stop
panel. The placement tool is a normal stacked tool (`toolStack.push`) whose
overlay is a direct `ActionDescriptor` child, the same mount the game uses for
mission arrows. It does not replace the Line Manager or monkey-patch module
functions. Other UI mods replacing the same recipes conflict silently: the game
keeps one replacement per recipe.

## Trying it locally

Build the ZIP with `python3 scripts/package_release.py`. Back up the save you test
with. Open the game's user-data folder from Settings → Advanced, then put the
`easier_waypoints_1` folder from the ZIP into its development `staging_area`.
Restart the game and enable Easier Waypoints. In the Line Manager, select a line,
then the stretch to edit, and press **Place Waypoint**.

In-game checks still needed, in order:

1. The mod loads without errors (check `stdout.txt` in the user-data folder).
2. The placement tool's highlight, arrows and markers appear. Check whether the
   native-flow tooltip overlay also appears; it may not render from a tooltip.
3. Arrows match real traffic on both sides of a two-way road, a one-way road, a
   tram street and a junction approach. Tracks show both ways.
4. Clicks add exactly one waypoint each, in order, on the highlighted lane. Back
   returns to the Line Manager with its state intact; hovering edits nothing.
5. After moving a waypoint (no stretch selected), the panel's stretch matches where
   the next native Shift-click lands.
6. Ship and aircraft markers and rejections behave; gamepad focus on the stop list
   still works; bridges, tunnels, slopes and UI scaling look right.

## Development checks

```sh
lua5.4 tests/direction_test.lua
lua5.4 tests/ui_contract_test.lua
luajit tests/direction_test.lua
luajit tests/ui_contract_test.lua
python3 -m unittest discover -s tests -p '*_test.py'
python3 scripts/package_release.py
```

The game embeds Lua 5.2.2. The Lua tests run on 5.4 and on LuaJIT (5.1-based), and
`tests/lua_compat_test.py` rejects 5.3+ syntax and libraries as well as 5.1-only
globals in runtime Lua. The UI contract test uses test doubles for native engine
objects. To also exercise the shipped Lua React registry, set `TF3_REACT_LUA` to
your own game's `gui/main/react.lua` extracted from `base/content/gui.zip`. Game
source is not included in this repository or its packages. Offline checks do not
validate the native C++ renderer, input handling or mod loader.

## Versioning and release tooling

Adapted from [Subsidy Manager](https://github.com/Ashcutus/Transport-Fever-3-Subsidy-Tracker):

- `VERSION` holds the public `MAJOR.MINOR.PATCH` label. `mod.json` has a separate
  integer `revision`; increment it when changing shipped files, including metadata.
  Tooling-only changes do not require a game revision bump.
- Update the visible Changes section in `_metadata/modinfo.json` for each release.
- `scripts/package_release.py` builds a deterministic runtime-only ZIP and SHA-256
  checksum. It never uploads or publishes anything.
- Start each in-game upload changelog with `vMAJOR.MINOR.PATCH`, for example
  `v0.2.0 — Placement tool for every line type`.
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
