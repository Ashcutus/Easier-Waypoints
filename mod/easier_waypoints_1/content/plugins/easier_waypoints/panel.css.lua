local ssu = require "::/gui/main/stylesheetutil.lua"

-- The row lines up with the stop names (20 spacer + 30 indicator + 1 margin) and
-- the button keeps the stop rows' 20-unit height.
-- Margins and paddings are { top, right, bottom, left }.
function data()
    local result = {}
    local a = ssu.makeAdder(result)
    local stopNameIndent = 20 + 30 + 1
    a("R::EasierWaypointsPanel !ew-waypoint-row", {
        margin = { 2, 0, 2, stopNameIndent },
        gravity = { -1, 0 },
    })
    a("R::EasierWaypointsPanel Button!ew-add-waypoint", {
        gravity = { 0, 0.5 },
        padding = { 2, 8, 2, 6 },
        minSize = { 0, 20 },
    })
    a("R::EasierWaypointsPanel Button!ew-add-waypoint BoxLayout", {
        innerSpacing = { 4, 0 },
    })
    a("R::EasierWaypointsPanel Button!ew-add-waypoint ImageView", {
        size = { 16, 16 },
        gravity = { 0, 0.5 },
    })
    a("R::EasierWaypointsPanel Button!ew-add-waypoint TextView", {
        gravity = { 0, 0.5 },
    })
    return result
end
