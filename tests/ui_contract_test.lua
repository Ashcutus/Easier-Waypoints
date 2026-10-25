-- No game installation needed. Native renderer objects are test doubles.
local root = "mod/easier_waypoints_1/content/plugins/easier_waypoints/"
local model = dofile(root .. "direction.lua")
local registry, replacements = {}, {}
local react = {
    RegisterRecipe = function(name, fn) local recipe = {name = name, fn = fn}; registry[name] = recipe; return recipe end,
    CallOriginalRecipe = function(original, param) return {kind = "original", recipe = original, param = param} end,
}
local function node(kind) return function(params) params.kind = kind; return params end end
local builtin = {BoxLayout = node("layout"), TextView = node("text"), EdgeRenderable = node("overlay"),
    type = {Orientation = {Vertical = 1}, EdgeRenderable = {Edge = {new = function(geometry) return {geometry = geometry} end}}}}
local function vec(x, y, z, w) return {x = x, y = y, z = z, w = w} end
local geometry = {}
local edge = {geometry = geometry, transportModes = {BUS = true}, forwardOnly = true}
local exists = true
local api = {
    type = {ComponentType = {BASE_EDGE_STREET = "road", TRANSPORT_NETWORK = "network", NAME = "name"},
        ["enum"] = {TransportMode = {BUS = "BUS", TRUCK = "TRUCK", CAR = "CAR"}, Carrier = {ROAD = "road"}},
        Vec2f = {new = vec}, Vec4f = {new = vec},
        EdgeGeometry = {new = function() return {} end, Type = {STRAIGHT = 1}, Straight = {new = function() return {} end},
            calcPos = function() return {{x = 10, y = 20, z = 3}, {x = 1, y = 0, z = 0}} end}},
    engine = {entityExists = function() return exists end,
        getComponent = function(entity, component)
            if component == "road" then return {} end
            if component == "network" then return {edges = {edge}} end
            if component == "name" then return {name = "Station " .. entity} end
        end},
    cmd = setmetatable({}, {__index = function() error("Visual prototype must never issue commands") end}),
}
local nativePanel = {name = "native panel"}
local tooltips = {LMAddWaypoint = {}, LMPromptWaypointModifier = {}, LMMoveWaypointTarget = {}}
local ui = {makeTooltip = function(text) return {kind = "tooltip", text = text} end}
local function environment(reactApi, builtins, tips, panel)
    return setmetatable({api = api, _ = function(text) return text end, ug_require = function(path)
        if path:find("/react.lua", 1, true) then return reactApi end
        if path:find("/builtin.lua", 1, true) then return builtins end
        if path:find("manager_tooltips_util.tl", 1, true) then return tips end
        if path:find("line_manager_panel.tl", 1, true) then return panel end
        if path:find("line_react_util.tl", 1, true) then return ui end
        if path:find("direction.lua", 1, true) then return model end
        error("Unexpected import " .. path)
    end}, {__index = _G})
end
local env = environment(react, builtin, tooltips, nativePanel)
assert(loadfile(root .. "main.script.lua", "t", env))()
env.data().install({ReplaceRecipe = function(original, replacement) replacements[original] = replacement end})
local count = 0
for _ in pairs(replacements) do count = count + 1 end
assert(count == 4, "Only three tooltip recipes and the stop panel are replaced")
local candidate = {edgePos = {edgeId = {entity = 1, index = 0}, param = 0.5}}
local result = replacements[tooltips.LMAddWaypoint].fn(candidate)
assert(result.kind == "layout" and #result.children == 3)
assert(result.children[1].recipe == tooltips.LMAddWaypoint and result.children[1].param == candidate)
assert(result.children[2].text:find("travel follows the arrow", 1, true))
local overlay = result.children[3]
assert(overlay.kind == "overlay" and #overlay.edges == 4 and not overlay.ignoreDepth)
assert(overlay.edges[1].geometry == geometry, "Highlight the actual snapped lane")
edge.forwardOnly = false
result = replacements[tooltips.LMMoveWaypointTarget].fn(candidate)
assert(#result.children[3].edges == 7 and result.children[2].text:find("both directions", 1, true))
exists = false
result = replacements[tooltips.LMAddWaypoint].fn(candidate)
assert(#result.children == 1 and result.children[1].param == candidate, "Stale lane falls back without overlay")
exists = true
result = replacements[tooltips.LMPromptWaypointModifier].fn({pos = {x = 1, y = 2, z = 3}})
assert(#result.children == 1, "Ship/aircraft feedback unchanged")
local constructor = builtin.type.EdgeRenderable.Edge.new
builtin.type.EdgeRenderable.Edge.new = function() error("unsupported renderer") end
result = replacements[tooltips.LMAddWaypoint].fn(candidate)
assert(#result.children == 1, "Unavailable renderer retains native tooltip")
builtin.type.EdgeRenderable.Edge.new = constructor
local common = {
    lineState = {old = function() return {carrierFilter = {road = true}, path = {{stop = {stationGroup = 10}}, {waypoint = {}}, {stop = {stationGroup = 20}}}} end},
    getModeState = function() return {"SEGMENT", 2} end,
}
local params = {commonParams = common}
result = replacements[nativePanel].fn(params)
assert(result.children[1].text == "Editing stretch: Station 10 → Station 20")
assert(result.children[#result.children].recipe == nativePanel and result.children[#result.children].param == params)
local roadLine = common.lineState.old
common.lineState.old = function() return {carrierFilter = {rail = true}, path = {}} end
result = replacements[nativePanel].fn(params)
assert(#result.children == 1 and result.children[1].recipe == nativePanel, "No road guidance on rail-only lines")
common.lineState.old = roadLine
assert(candidate.edgePos.param == 0.5 and candidate.edgePos.edgeId.index == 0)
print("PASS: UI delegation, candidate overlays, invalid-data fallback and no simulation commands")

-- Optional: execute the actual shipped Lua recipe registry with opaque node IDs.
local nativeReactPath = os.getenv("TF3_REACT_LUA")
if not nativeReactPath then
    print("SKIP: shipped React registry check (set TF3_REACT_LUA)")
    return
end
local store = {builtin = {BoxLayout = 1, TextView = 2, EdgeRenderable = 3, WithComponentParams = 4}, recipes = {},
    recipeMetas = {}, originalRecipeFn = {}, recipeReplace = {}, tools = {}, recipeReplacementAllowed = true, extensionPoints = {}}
local ids, nextId, nodes = {}, 100, {}
local hostApi = {gui = {react = {params = {builtin = {WithComponentParams = {new = function() return {} end}}}, detail = {makeRecipeId = function(name)
    if not ids[name] then nextId = nextId + 1; ids[name] = nextId end
    return ids[name]
end}}}}
local host = setmetatable({_react = store, api = hostApi,
    log = {verbose = function() end, warning = function() end, error = function(message) error(message) end},
    require = function(path)
        assert(path == "/scripts/string_util.tl")
        return {format = function(message, values) return (message:gsub("{(.-)}", function(k) return tostring(values[k]) end)) end}
    end,
    ug_require = function(path) assert(path == "/scripts/util.tl"); return {} end}, {__index = _G})
local realReact = assert(loadfile(nativeReactPath, "t", host))()
local realBuiltin = {type = builtin.type}
for name in pairs(store.builtin) do realBuiltin[name] = realReact.DeclareBuiltin(name, function() end) end
local function original(name) return realReact.RegisterRecipe(name, function() return realBuiltin.BoxLayout {children = {}} end) end
local realTips = {LMAddWaypoint = original("NativeAdd"), LMPromptWaypointModifier = original("NativePrompt"), LMMoveWaypointTarget = original("NativeMove")}
local realPanel = original("NativePanel")
local realEnv = environment(realReact, realBuiltin, realTips, realPanel)
assert(loadfile(root .. "main.script.lua", "t", realEnv))()
realEnv.data().install({ReplaceRecipe = realReact.GloballyReplaceRecipeBeforeInitInternal})
local context = {}
function context:makeNodeWithProps(recipeId, _, props)
    nodes[#nodes + 1] = {recipeId = recipeId, props = props}
    return #nodes -- opaque ID, not a mutable node table
end
function context:setResult(children)
    assert(#children == 1 and nodes[children[1]].recipeId == store.builtin.BoxLayout,
        "Replacement recipes must return a layout")
    self.result = nodes[children[1]]
end
for _, recipe in ipairs({realTips.LMAddWaypoint, realTips.LMPromptWaypointModifier, realTips.LMMoveWaypointTarget, realPanel}) do
    local id = realReact.GetRecipeId(recipe)
    local replacement = assert(store.recipeReplace[id])
    local replacementId = realReact.GetRecipeId(replacement)
    local arg = recipe == realPanel and params or candidate
    store.recipes[replacementId](context, {props = {arg}})
    assert(context.result)
end
print("PASS: shipped TF3 Lua React registration/replacement with opaque node IDs (native C++ untested)")
