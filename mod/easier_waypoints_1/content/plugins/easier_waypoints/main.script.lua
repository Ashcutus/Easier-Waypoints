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
        if instruction then children[#children + 1] = game.tooltipText(instruction(), true) end
        for _, child in ipairs(laneChildren(waypoint)) do children[#children + 1] = child end
        return vertical(children)
    end)
end

-- Plain data first; nodes are only created once every lookup has succeeded.
local function panelState(common)
    local line = common.lineState and common.lineState:old()
    local mode = common.getModeState()
    if not line or not line.path or not mode then return nil end
    if mode[1] == "MOVE_WAYPOINT" then
        return {hint = _("Click the new location for the waypoint, or press [iaHint=IA_MENU_BACK/] to cancel.")}
    end
    if mode[1] ~= "SEGMENT" then return nil end
    local text = game.stretchText(line, mode[2], _("New waypoints go between {from} and {to}."))
    if not text then return {hint = _("Select a stretch of the line to add waypoints to it.")} end
    return {
        text = text,
        hint = _("To add a waypoint, hold [iaHint=IA_PRECISION_MODE/] and click in the world, or use Place Waypoint."),
        place = true,
    }
end

local Panel = react.RegisterRecipe("EasierWaypointsPanel", function(params)
    local children = {}
    local ok, state = pcall(panelState, params.commonParams)
    if ok and state then
        if state.text then
            -- Display names are plain text: never insert them into rich-text markup.
            children[#children + 1] = builtin.TextView {meta = {class = "font-scale-body"}, text = state.text}
        end
        children[#children + 1] = builtin.TextView {
            meta = {class = "font-scale-annotation"}, text = state.hint, inlineHintSupport = true,
        }
        if state.place then
            children[#children + 1] = buttons.makeTextButton("primary", _("Place Waypoint"), function()
                placement.start(params.commonParams)
            end, _("Highlights the lane and its direction under the cursor before you click."), false)
        end
    end
    children[#children + 1] = react.CallOriginalRecipe(nativePanel, params)
    return vertical(children)
end)

local replacements = {
    {tooltips.LMAddWaypoint, tooltipReplacement("EasierWaypointsAdd", tooltips.LMAddWaypoint)},
    {tooltips.LMPromptWaypointModifier, tooltipReplacement("EasierWaypointsPrompt", tooltips.LMPromptWaypointModifier, function()
        return _("Clicking alone does nothing here: hold [iaHint=IA_PRECISION_MODE/] while clicking to add the waypoint.")
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
