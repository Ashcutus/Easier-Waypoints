local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local buttons = ug_require "::/gui/main/button_react_util.tl"
local tooltips = ug_require "::/gui/line_vehicle_mgmt/manager_tooltips_util.tl"
local nativePanel = ug_require "::/gui/line_vehicle_mgmt/line_manager_panel.tl"
local game = ug_require "easier_waypoints::/plugins/easier_waypoints/game.lua"
local placement = ug_require "easier_waypoints::/plugins/easier_waypoints/placement.lua"

game.reportRuntime()

local function vertical(children)
    return builtin.BoxLayout {orientation = builtin.type.Orientation.Vertical, children = children}
end

-- Tooltips are text only: the engine aborts if world graphics are built inside a
-- tooltip tree. Lane previews live in the placement tool.
local Prompt = react.RegisterRecipe("EasierWaypointsPrompt", function(waypoint)
    -- Always return a layout, including native fallback; recipe nodes are opaque.
    return vertical({
        react.CallOriginalRecipe(tooltips.LMPromptWaypointModifier, waypoint),
        game.tooltipText(_("Hold the key shown above while clicking, or use Add Waypoint in the line panel.")),
    })
end)

local WAYPOINT_ICON = "::/gui/construction/menu/menu_categories/category_waypoints.tga"

-- Only while a line is being edited; the stretch lives in the tooltip so the
-- panel keeps a single compact row. Plain data first, nodes afterwards.
local function panelState(common)
    local line = common.lineState and common.lineState:old()
    local mode = common.getModeState()
    if not line or not line.path or not mode or mode[1] ~= "SEGMENT" then return nil end
    -- One literal per message so translation extraction can find it.
    local text = game.stretchText(line, mode[2],
        _("Add waypoints between {from} and {to}.\nYou'll see the lane and its direction before you click.\nClick the route to switch to another part of the line.\nRight-click or press Esc when you're done."))
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
    {tooltips.LMPromptWaypointModifier, Prompt},
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
