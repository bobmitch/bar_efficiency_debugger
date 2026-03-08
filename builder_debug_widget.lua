-- builder_debug_widget.lua
--
-- Tick-rate debug overlay: lists every builder unit owned by the local player,
-- showing per-tick metal usage (Spring.GetUnitResources pull) vs the theoretical
-- maximum metal draw for the unit currently being constructed.
--
-- Fully self-contained — does NOT rely on globals from widget_charts.lua.
-- Mirrors the builder tracking logic from widget_charts.lua exactly so that
-- discrepancies between the two can be spotted directly.
--
-- Permanent — not affected by chartsEnabled, config, or visibility toggles.

if not RmlUi then
    Spring.Echo("[BuilderDebug] RmlUi not available, skipping.")
    return
end

local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name    = "Builder Efficiency Debug",
        desc    = "Per-tick overlay showing builder metal usage vs max — debug companion to BAR Charts",
        author  = "FilthyMitch",
        date    = "2026",
        license = "MIT",
        layer   = 10,
        enabled = true,
    }
end

-------------------------------------------------------------------------------
-- CONSTANTS
-------------------------------------------------------------------------------

local MODEL_NAME = "builder_debug_model"
local RML_PATH   = "luaui/widgets/builder_debug_widget.rml"

-------------------------------------------------------------------------------
-- STATE  (mirrors widget_charts.lua exactly)
-------------------------------------------------------------------------------

local teamID    = nil
local vsx, vsy  = Spring.GetViewGeometry()

-- unitID → { bp = buildSpeed, defID = unitDefID }
local builderUnits = {}

-- maxMetalUseCache[builderDefID][targetDefID] = metal/s at full build speed
-- Computed once per combo and cached forever (unit defs don't change at runtime).
local maxMetalUseCache = {}

local document  = nil
local dm_handle = nil

-------------------------------------------------------------------------------
-- HELPERS
-------------------------------------------------------------------------------

local function unitIsBuilder(unitDefID)
    if not unitDefID then return false end
    local ud = UnitDefs[unitDefID]
    return ud and ud.isBuilder and (ud.buildSpeed or 0) > 0
end

local function getMaxMetal(builderDefID, targetDefID, builderBP)
    if not builderDefID or not targetDefID then return 0 end
    local row = maxMetalUseCache[builderDefID]
    if row then
        local cached = row[targetDefID]
        if cached ~= nil then return cached end
    end
    -- First time — compute and store
    local bud = UnitDefs[builderDefID]
    local tud = UnitDefs[targetDefID]
    local result = 0
    if bud and tud then
        local bt = tud.buildTime or 1
        if bt <= 0 then bt = 1 end
        result = (builderBP / bt) * (tud.metalCost or 0)
    end
    if not maxMetalUseCache[builderDefID] then
        maxMetalUseCache[builderDefID] = {}
    end
    maxMetalUseCache[builderDefID][targetDefID] = result
    return result
end

local function truncate(s, maxLen)
    if not s then return "?" end
    if #s > maxLen then return string.sub(s, 1, maxLen - 2) .. ".." end
    return s
end

local function fmt2(n)
    return string.format("%.3f", n or 0)
end

-------------------------------------------------------------------------------
-- SEED — scan all existing units on init (handles loading mid-game)
-------------------------------------------------------------------------------

local function seedBuilders()
    builderUnits = {}
    teamID = Spring.GetMyTeamID()
    if not teamID then return end
    local units = Spring.GetTeamUnits(teamID) or {}
    for _, uid in ipairs(units) do
        local defID = Spring.GetUnitDefID(uid)
        if unitIsBuilder(defID) then
            local ud = UnitDefs[defID]
            builderUnits[uid] = { bp = ud.buildSpeed, defID = defID }
        end
    end
    Spring.Echo(string.format("[BuilderDebug] Seeded %d builder(s) for team %d", #units, teamID))
end

-------------------------------------------------------------------------------
-- BUILD DATA FOR MODEL
-------------------------------------------------------------------------------

local function buildRows()
    local rows = {}

    for uid, data in pairs(builderUnits) do
        local bp    = data.bp
        local defID = data.defID
        local bud   = defID and UnitDefs[defID]
        local builderName = truncate(bud and (bud.humanName or bud.name) or ("def#"..tostring(defID)), 20)

        -- What is this builder currently constructing?
        local targetUID   = Spring.GetUnitIsBuilding(uid)
        local targetDefID = targetUID and Spring.GetUnitDefID(targetUID)
        local tud         = targetDefID and UnitDefs[targetDefID]
        local targetName  = truncate(
            tud and (tud.humanName or tud.name) or (targetUID and ("uid#"..targetUID) or "—"),
            20
        )

        -- Actual metal draw this tick via GetUnitResources
        -- Returns: currentLevel, pull, income, expense, share
        local _, mPull = Spring.GetUnitResources(uid, "metal")
        local mUsing   = mPull or 0

        -- Theoretical max metal/s for this builder+target combo
        local maxMetal = 0
        if targetDefID then
            maxMetal = getMaxMetal(defID, targetDefID, bp)
        end

        -- Efficiency ratio
        local ratioStr
        if targetUID then
            if maxMetal > 0 then
                local r = math.min(1.0, mUsing / maxMetal)
                ratioStr = string.format("%.0f%%", r * 100)
            else
                -- Cache not yet populated or zero-cost target
                ratioStr = "?% (no max)"
            end
        else
            ratioStr = "idle"
        end

        rows[#rows + 1] = {
            uid    = tostring(uid),
            name   = builderName,
            bp     = string.format("%.0f", bp),
            target = targetName,
            active = targetUID and "YES" or "no",
            using  = fmt2(mUsing),
            max    = maxMetal > 0 and fmt2(maxMetal) or "—",
            ratio  = ratioStr,
        }
    end

    table.sort(rows, function(a, b) return tonumber(a.uid) < tonumber(b.uid) end)

    if #rows == 0 then
        rows[1] = {
            uid = "—", name = "(no builders tracked)", bp = "—",
            target = "—", active = "—", using = "—", max = "—", ratio = "—",
        }
    end

    return rows
end

local function buildSummary()
    local total    = 0
    local active   = 0
    local effSum   = 0
    local effCount = 0

    for uid, data in pairs(builderUnits) do
        total = total + 1
        local targetUID   = Spring.GetUnitIsBuilding(uid)
        local targetDefID = targetUID and Spring.GetUnitDefID(targetUID)
        if targetUID then
            active = active + 1
            local maxMetal = targetDefID and getMaxMetal(data.defID, targetDefID, data.bp) or 0
            local _, mPull = Spring.GetUnitResources(uid, "metal")
            local mUsing   = mPull or 0
            if maxMetal > 0 then
                effSum   = effSum   + math.min(1.0, mUsing / maxMetal)
                effCount = effCount + 1
            end
        end
    end

    local effPct
    if effCount > 0 then
        effPct = effSum / effCount * 100
    elseif total > 0 then
        effPct = 100  -- all idle, same fallback as widget_charts
    else
        effPct = 0
    end

    return string.format(
        "builders tracked: %d  |  active (building): %d  |  active with cached max: %d  |  computed eff: %.1f%%",
        total, active, effCount, effPct
    )
end

-------------------------------------------------------------------------------
-- WIDGET LIFECYCLE
-------------------------------------------------------------------------------

function widget:Initialize()
    vsx, vsy = Spring.GetViewGeometry()
    teamID   = Spring.GetMyTeamID()

    widget.rmlContext = RmlUi.GetContext("shared")
    if not widget.rmlContext then
        Spring.Echo("[BuilderDebug] RmlUi shared context not found — is rml_setup.lua loaded?")
        widgetHandler:RemoveWidget(self)
        return
    end

    dm_handle = widget.rmlContext:OpenDataModel(MODEL_NAME, {
        rows    = {},
        summary = "initialising...",
    })
    if not dm_handle then
        Spring.Echo("[BuilderDebug] Failed to open data model '" .. MODEL_NAME .. "'")
        widgetHandler:RemoveWidget(self)
        return
    end

    document = widget.rmlContext:LoadDocument(RML_PATH, widget)
    if not document then
        Spring.Echo("[BuilderDebug] Failed to load RML document: " .. RML_PATH)
        widgetHandler:RemoveWidget(self)
        return
    end

    -- Position: centred horizontally, 8px from bottom of screen
    local container = document:GetElementById("container")
    if container then
        local xPos = math.floor((vsx - 820) / 2)
        local yPos = 8
        container.style.left = xPos .. "px"
        container.style.top  = yPos .. "px"
    end

    document:ReloadStyleSheet()
    document:Show()

    -- Seed builder list if we're loading mid-game
    seedBuilders()

    Spring.Echo("[BuilderDebug] Initialised — tracking " .. (function()
        local n = 0; for _ in pairs(builderUnits) do n = n + 1 end; return n
    end)() .. " builder(s)")
end

function widget:Shutdown()
    if widget.rmlContext then
        widget.rmlContext:RemoveDataModel(MODEL_NAME)
    end
    if document then
        document:Close()
        document = nil
    end
    dm_handle = nil
end

-------------------------------------------------------------------------------
-- UNIT EVENT HOOKS  (exact mirrors of widget_charts.lua)
-------------------------------------------------------------------------------

function widget:UnitFinished(unitID, unitDefID, unitTeam)
    if unitTeam ~= teamID then return end
    if unitIsBuilder(unitDefID) then
        local ud = UnitDefs[unitDefID]
        builderUnits[unitID] = { bp = ud.buildSpeed, defID = unitDefID }
        Spring.Echo(string.format("[BuilderDebug] Builder added: uid=%d  name=%s  bp=%.0f",
            unitID, ud.humanName or ud.name or "?", ud.buildSpeed))
    end
end

function widget:UnitCreated(unitID, unitDefID, unitTeam)
    -- Commanders and factory-spawned units fire UnitCreated before UnitFinished.
    -- Track them immediately so they appear on screen from the start.
    if unitTeam ~= teamID then return end
    if unitIsBuilder(unitDefID) then
        local ud = UnitDefs[unitDefID]
        if not builderUnits[unitID] then
            builderUnits[unitID] = { bp = ud.buildSpeed, defID = unitDefID }
            Spring.Echo(string.format("[BuilderDebug] Builder created: uid=%d  name=%s  bp=%.0f",
                unitID, ud.humanName or ud.name or "?", ud.buildSpeed))
        end
    end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam)
    if unitTeam == teamID then
        builderUnits[unitID] = nil
    end
end

function widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
    if oldTeam == teamID then builderUnits[unitID] = nil end
    if newTeam == teamID and unitIsBuilder(unitDefID) then
        local ud = UnitDefs[unitDefID]
        builderUnits[unitID] = { bp = ud.buildSpeed, defID = unitDefID }
    end
end

function widget:UnitCaptured(unitID, unitDefID, oldTeam, newTeam)
    widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
end

-------------------------------------------------------------------------------
-- UPDATE — runs every tick, no throttle
-------------------------------------------------------------------------------

function widget:Update(dt)
    if not dm_handle then return end

    -- Lazily acquire teamID (may not be available at Initialize time in some game modes)
    if not teamID then
        teamID = Spring.GetMyTeamID()
        if teamID then seedBuilders() end
        return
    end

    dm_handle.rows    = buildRows()
    dm_handle.summary = buildSummary()
end
