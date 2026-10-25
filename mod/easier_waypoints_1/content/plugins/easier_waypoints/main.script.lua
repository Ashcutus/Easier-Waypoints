local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local buttons = ug_require "::/gui/main/button_react_util.tl"
local tooltips = ug_require "::/gui/line_vehicle_mgmt/manager_tooltips_util.tl"
local nativePanel = ug_require "::/gui/line_vehicle_mgmt/line_manager_panel.tl"
local direction = ug_require "easier_waypoints::/plugins/easier_waypoints/direction.lua"
local game = ug_require "easier_waypoints::/plugins/easier_waypoints/game.lua"
local placement = ug_require "easier_waypoints::/plugins/easier_waypoints/placement.lua"

local function vertical(children)
    return builtin.BoxLayout {orientation = builtin.type.Orientation.Vertical, children = children}
end

-- Tooltips only receive the hovered candidate. Bad lane data keeps the native
-- tooltip; direction text is only shown alongside an overlay that was built.
local function laneChildren(waypoint)
    local ok, preview = pcall(direction.preview, waypoint, game.backend)
    if not ok then game.warnOnce("tooltip lane data unreadable", preview) end
    if not ok or not preview then return {} end
    local rendered, overlay = pcall(game.laneOverlay, preview, true)
    if rendered and overlay then
        return {game.tooltipText(game.directionText(preview)), overlay}
    end
    game.warnOnce("tooltip lane preview unavailable", rendered and "nothing to draw" or overlay)
    return {game.tooltipText(game.previewUnavailableText(false, false))}
end

local function tooltipReplacement(name, original, instruction)
    return react.RegisterRecipe(name, function(waypoint)
        -- Always return a layout, including native fallback; recipe nodes are opaque.
        local children = {react.CallOriginalRecipe(original, waypoint)}
        if instruction then children[#children + 1] = game.tooltipText(instruction()) end
        for _, child in ipairs(laneChildren(waypoint)) do children[#children + 1] = child end
        return vertical(children)
    end)
end

local WAYPOINT_ICON = "::/gui/construction/menu/menu_categories/category_waypoints.tga"

-- Only while a line is being edited; the stretch lives in the tooltip so the
-- panel keeps a single compact row. Plain data first, nodes afterwards.
local function panelState(common)
    local line = common.lineState and common.lineState:old()
    local mode = common.getModeState()
    if not line or not line.path or not mode or mode[1] ~= "SEGMENT" then return nil end
    -- One literal per message so translation extraction can find it.
    local text = game.stretchText(line, mode[2],
        _("Adds waypoints between {from} and {to}, with a lane and direction preview. Click the route to choose another part of the line. Right-click or press Esc to finish."))
    if not text then return {enabled = false, tooltip = _("Select a stretch of the line first.")} end
    return {enabled = true, tooltip = text}
end

local Panel = react.RegisterRecipe("EasierWaypointsPanel", function(params)
    local children = {}
    local ok, state = pcall(panelState, params.commonParams)
    if ok and state then
        children[#children + 1] = builtin.Component {
            meta = {class = "ew-waypoint-row"},
            layout = builtin.BoxLayout {
                orientation = builtin.type.Orientation.Horizontal,
                children = {buttons.makeIconTextButton("secondary, ew-add-waypoint", WAYPOINT_ICON, _("Add Waypoint"),
                    function() placement.start(params.commonParams) end, state.tooltip, state.enabled, nil,
                    "font-scale-annotation")},
            },
        }
    end
    children[#children + 1] = react.CallOriginalRecipe(nativePanel, params)
    return vertical(children)
end)

local replacements = {
    {tooltips.LMAddWaypoint, tooltipReplacement("EasierWaypointsAdd", tooltips.LMAddWaypoint)},
    {tooltips.LMPromptWaypointModifier, tooltipReplacement("EasierWaypointsPrompt", tooltips.LMPromptWaypointModifier, function()
        return _("Hold the key shown above while clicking. A click on its own does nothing here.")
    end)},
    {tooltips.LMMoveWaypointTarget, tooltipReplacement("EasierWaypointsMove", tooltips.LMMoveWaypointTarget)},
    {nativePanel, Panel},
}

function data()
    return {
        install = function(replacementApi)
            for _, pair in ipairs(replacements) do
                replacementApi.ReplaceRecipe(pair[1], pair[2])
            end
        end,
    }
end
