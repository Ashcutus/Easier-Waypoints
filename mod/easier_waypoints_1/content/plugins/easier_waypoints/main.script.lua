local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local buttons = ug_require "::/gui/main/button_react_util.tl"
local tooltips = ug_require "::/gui/line_vehicle_mgmt/manager_tooltips_util.tl"
local nativePanel = ug_require "::/gui/line_vehicle_mgmt/line_manager_panel.tl"
local lineUtil = ug_require "::/gui/line_vehicle_mgmt/line_util.tl"
local appUtil = ug_require "::/scripts/app_util.tl"
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

local function finishHint()
    if appUtil.isGamepadInputMode() then return _("Use Back when you're done.") end
    return _("Right-click or press Esc when you're done.")
end

-- Keep Finish available while the placement tool is active, including when a
-- native panel action changes the editing mode. The stretch stays in the tooltip.
local function panelState(common)
    if placement.isActive(common) then
        return {active = true, enabled = true,
            tooltip = _("Finish placing waypoints and return to normal line editing.") .. "\n" .. finishHint()}
    end
    local line = common.lineState and common.lineState:old()
    local mode = common.getModeState()
    if not line or not line.path or not mode or mode[1] ~= "SEGMENT" then return nil end
    -- One literal per message so translation extraction can find it.
    local text = game.stretchText(line, mode[2], _("Add waypoints between {from} and {to}."))
    if not text then return {enabled = false, tooltip = _("Select a stretch of the line first.")} end
    local carriers = game.lineCarriers(lineUtil.getLineCarriers(line))
    local guidance = (carriers.WATER or carriers.AIR) and _("Preview the point before you click.")
        or _("Preview the lane and any confirmed direction before you click.\nClick the route to add a waypoint to that part of the line.")
    return {enabled = true, tooltip = text .. "\n" .. guidance .. "\n" .. finishHint()}
end

local function readPanelState(common)
    local ok, state = pcall(panelState, common)
    if not ok then game.warnOnce("waypoint button state unavailable", state); return nil end
    return state
end

local function samePanelState(a, b)
    if not a or not b then return a == b end
    return a.active == b.active and a.enabled == b.enabled and a.tooltip == b.tooltip
end

local Panel = react.RegisterRecipe("EasierWaypointsPanel", function(params)
    local children = {}
    local stateHook = react.useState(readPanelState(params.commonParams))
    react.onStep(function()
        if stateHook.hasExpired and stateHook:hasExpired() then return end
        local nextState = readPanelState(params.commonParams)
        if not samePanelState(stateHook:old(), nextState) then stateHook:set(nextState) end
    end)
    local state = stateHook:old()
    if state then
        children[#children + 1] = builtin.Component {
            meta = {class = "ew-waypoint-row"},
            layout = builtin.BoxLayout {
                orientation = builtin.type.Orientation.Horizontal,
                children = {buttons.makeIconTextButton("secondary, ew-add-waypoint", WAYPOINT_ICON,
                    state.active and _("Finish Waypoints") or _("Add Waypoint"), function()
                        if placement.isActive(params.commonParams) then placement.finish(params.commonParams)
                        else placement.start(params.commonParams) end
                    end, state.tooltip, state.enabled, nil,
                    "font-scale-annotation")},
            },
        }
    end
    children[#children + 1] = react.CallOriginalRecipe(nativePanel, params)
    return vertical(children)
end)

-- Waypoint rows in the stop list are blank: the row text field only names stops.
-- The row recipe is private to the stop list, so it is replaced through the React
-- registry by name (operator-approved exception). If the registry is not as
-- expected or another mod already replaced the row, rows stay native.
local STOP_ROW = "LineStopItem"
local originalRow

local function rowLabel(params)
    local path = params.viaState and params.viaState:old()
    local via = path and path[params.stopNumber]
    if not via or not via.waypoint then return nil end
    local line = params.commonParams and params.commonParams.lineState and params.commonParams.lineState:old()
    return game.waypointLabel(via.waypoint, game.lineCarriers(line and lineUtil.getLineCarriers(line)))
end

local function readRowLabel(params)
    local ok, label = pcall(rowLabel, params)
    if not ok then
        game.warnOnce("stop row label failed", label)
        return nil
    end
    return label
end

local StopRow = react.RegisterRecipe("EasierWaypointsStopItem", function(params)
    -- Native rows update themselves independently; poll here too so a road rename
    -- or lane revision updates this wrapper without waiting for new row params.
    local labelState = react.useState(readRowLabel(params))
    react.onStep(function()
        if labelState.hasExpired and labelState:hasExpired() then return end
        local nextLabel = readRowLabel(params)
        if labelState:old() ~= nextLabel then labelState:set(nextLabel) end
    end)
    local native = originalRow(params)
    local label = labelState:old()
    -- Stop rows are returned untouched so their layout is exactly native.
    if not label then return native end
    return builtin.FloatingLayout {meta = {class = "ew-waypoint-row-layout"}, children = {
        builtin.FloatingLayoutChild {h = -1, v = -1, item = native},
        builtin.FloatingLayoutChild {h = 0, v = 0.5, item = builtin.Component {
            meta = {class = "ew-waypoint-label", mouseTransparent = true},
            layout = builtin.BoxLayout {children = {builtin.TextView {
                meta = {class = "font-scale-body"}, text = label, tooltipWhenClipped = label,
            }}},
        }},
    }}
end)

local function replacePrivateRow()
    local registry = _react
    local detail = api.gui.react and api.gui.react.detail
    if type(registry) ~= "table" or not detail or not detail.makeRecipeId then return "registry unavailable" end
    local id = detail.makeRecipeId(STOP_ROW)
    if not (registry.recipes and registry.recipes[id] and registry.originalRecipeFn and registry.originalRecipeFn[id]) then
        return "stop row recipe not found"
    end
    if not registry.recipeReplace or registry.recipeReplace[id] then return "stop row already replaced" end
    if registry.recipeReplacementAllowed == false then return "replacement window closed" end
    originalRow = registry.originalRecipeFn[id]
    registry.recipeReplace[id] = StopRow
    return nil
end

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
            local ok, problem = pcall(replacePrivateRow)
            if not ok or problem then game.warnOnce("waypoint row text unavailable", ok and problem or tostring(problem)) end
        end,
    }
end
