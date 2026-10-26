local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local buttons = ug_require "::/gui/main/button_react_util.tl"
local tooltips = ug_require "::/gui/line_vehicle_mgmt/manager_tooltips_util.tl"
local nativePanel = ug_require "::/gui/line_vehicle_mgmt/line_manager_panel.tl"
local lineUtil = ug_require "::/gui/line_vehicle_mgmt/line_util.tl"
local lineReactUtil = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl"
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

local function readWaypointCount(entity)
    local ok, count = pcall(game.waypointCount, entity)
    if not ok then game.warnOnce("line waypoint count unavailable", count); return 0 end
    return count
end

-- This exported widget sits beside line names. Keep its native notifications
-- and add a non-focusable count without replacing the line's own controls.
local LineFeedback = react.RegisterRecipe("EasierWaypointsLineFeedback", function(entity)
    local countState = react.useState(readWaypointCount(entity))
    react.onStepTimer(function()
        if countState.hasExpired and countState:hasExpired() then return end
        local count = readWaypointCount(entity)
        if countState:old() ~= count then countState:set(count) end
    end, 0.25)
    local children = {}
    local count = countState:old()
    if count > 0 then
        children[#children + 1] = builtin.Component {
            meta = {class = "ew-line-waypoints", tooltip = game.waypointCountText(count)},
            layout = builtin.BoxLayout {orientation = builtin.type.Orientation.Horizontal, children = {
                builtin.ImageView {path = WAYPOINT_ICON},
                builtin.TextView {meta = {class = "font-scale-annotation"}, text = tostring(count)},
            }},
        }
    end
    children[#children + 1] = react.CallOriginalRecipe(lineReactUtil.ManagerNotificationWidget, entity)
    return builtin.BoxLayout {orientation = builtin.type.Orientation.Horizontal, children = children}
end)

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

local function usePanelState(common)
    local stateHook = react.useState(readPanelState(common))
    react.onStep(function()
        if stateHook.hasExpired and stateHook:hasExpired() then return end
        local nextState = readPanelState(common)
        if not samePanelState(stateHook:old(), nextState) then stateHook:set(nextState) end
    end)
    return stateHook:old()
end

-- From the "+" row with no stretch selected, select the stretch the row shows
-- (after the last entry) so the waypoint lands where the button is.
local function waypointRow(common, state, fromStopList)
    return builtin.Component {
        meta = {class = "ew-waypoint-row"},
        layout = builtin.BoxLayout {
            orientation = builtin.type.Orientation.Horizontal,
            children = {buttons.makeIconTextButton("secondary, ew-add-waypoint", WAYPOINT_ICON,
                state.active and _("Finish Waypoints") or _("Add Waypoint"), function()
                    if placement.isActive(common) then
                        placement.finish(common)
                        return
                    end
                    local mode = common.getModeState()
                    local line = common.lineState and common.lineState:old()
                    if fromStopList and mode and mode[1] == "SEGMENT" and mode[2] == nil and line and line.path then
                        common.switchMode({"SEGMENT", #line.path})
                    end
                    placement.start(common)
                end, state.tooltip, state.enabled, nil, "font-scale-annotation")},
        },
    }
end

-- The stop list draws its "+" row in SEGMENT mode at mode[2] (or the last entry).
local function stopListRowShown(common)
    local mode = common.getModeState()
    local line = common.lineState and common.lineState:old()
    if not mode or mode[1] ~= "SEGMENT" or not line or not line.path then return false end
    local insertAt = mode[2] or #line.path
    return type(insertAt) == "number" and insertAt >= 1 and insertAt <= #line.path
end

local stopListButton = false

-- The button lives on the stop list's "+" row when that patch is active. The top
-- row stays as the fallback: no "+" row, patch declined, or gamepad (the "+" row
-- is not focusable).
local function topRowShown(common)
    if not stopListButton or appUtil.isGamepadInputMode() then return true end
    local ok, shown = pcall(stopListRowShown, common)
    return not ok or not shown
end

local Panel = react.RegisterRecipe("EasierWaypointsPanel", function(params)
    local children = {}
    local state = usePanelState(params.commonParams)
    if state and topRowShown(params.commonParams) then
        children[#children + 1] = waypointRow(params.commonParams, state, false)
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

-- The "+ Add the next stop here" row: Add/Finish Waypoints goes on its own line
-- under the native box, which keeps the native row and its sizes untouched.
local STOP_LIST_PREVIEW = "LineStopItemPreview"
local originalPreview

local StopPreview = react.RegisterRecipe("EasierWaypointsStopPreview", function(params)
    local state = usePanelState(params.commonParams)
    local native = originalPreview(params)
    if not state or not stopListButton or appUtil.isGamepadInputMode() then return native end
    return builtin.BoxLayout {orientation = builtin.type.Orientation.Vertical, meta = {class = "ew-preview-layout"},
        children = {native, waypointRow(params.commonParams, state, true)}}
end)

-- Returns the original recipe, or nil and why the replacement was declined.
local function replacePrivate(name, replacement)
    local registry = _react
    local detail = api.gui.react and api.gui.react.detail
    if type(registry) ~= "table" or not detail or not detail.makeRecipeId then return nil, "registry unavailable" end
    local id = detail.makeRecipeId(name)
    if not (registry.recipes and registry.recipes[id] and registry.originalRecipeFn and registry.originalRecipeFn[id]) then
        return nil, name .. " recipe not found"
    end
    if not registry.recipeReplace or registry.recipeReplace[id] then return nil, name .. " already replaced" end
    if registry.recipeReplacementAllowed == false then return nil, "replacement window closed" end
    registry.recipeReplace[id] = replacement
    return registry.originalRecipeFn[id]
end

local replacements = {
    {tooltips.LMPromptWaypointModifier, Prompt},
    {nativePanel, Panel},
    {lineReactUtil.ManagerNotificationWidget, LineFeedback},
}

function data()
    return {
        install = function(replacementApi)
            for _, pair in ipairs(replacements) do
                replacementApi.ReplaceRecipe(pair[1], pair[2])
            end
            local ok, original, problem = pcall(replacePrivate, STOP_ROW, StopRow)
            if ok and original then originalRow = original
            else game.warnOnce("waypoint row text unavailable", ok and problem or tostring(original)) end
            ok, original, problem = pcall(replacePrivate, STOP_LIST_PREVIEW, StopPreview)
            if ok and original then originalPreview, stopListButton = original, true
            else game.warnOnce("stop list waypoint button unavailable", ok and problem or tostring(original)) end
        end,
    }
end
