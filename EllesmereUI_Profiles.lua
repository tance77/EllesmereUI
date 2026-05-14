-------------------------------------------------------------------------------
--  EllesmereUI_Profiles.lua
--
--  Global profile system: import/export, presets, spec assignment.
--  Handles serialization (LibDeflate + custom serializer) and profile
--  management across all EllesmereUI addons.
--
--  Load order (via TOC):
--    1. Libs/LibDeflate.lua
--    2. EllesmereUI_Lite.lua
--    3. EllesmereUI.lua
--    4. EllesmereUI_Widgets.lua
--    5. EllesmereUI_Presets.lua
--    6. EllesmereUI_Profiles.lua  -- THIS FILE
-------------------------------------------------------------------------------

local EllesmereUI = _G.EllesmereUI

-------------------------------------------------------------------------------
--  LibDeflate reference (loaded before us via TOC)
--  LibDeflate registers via LibStub, not as a global, so use LibStub to get it.
-------------------------------------------------------------------------------
local LibDeflate = LibStub and LibStub("LibDeflate", true) or _G.LibDeflate

-------------------------------------------------------------------------------
--  Reload popup: uses Blizzard StaticPopup so the button click is a hardware
--  event and ReloadUI() is not blocked as a protected function call.
-------------------------------------------------------------------------------
StaticPopupDialogs["EUI_PROFILE_RELOAD"] = {
    text = "EllesmereUI Profile switched. Reload UI to apply?",
    button1 = "Reload Now",
    button2 = "Later",
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-------------------------------------------------------------------------------
--  Addon registry: display-order list of all managed addons.
--  Each entry: { folder, display, svName }
--    folder  = addon folder name (matches _dbRegistry key)
--    display = human-readable name for the Profiles UI
--    svName  = SavedVariables name (e.g. "EllesmereUINameplatesDB")
--
--  All addons use _dbRegistry for profile access. Order matters for UI display.
-------------------------------------------------------------------------------
local ADDON_DB_MAP = {
    { folder = "EllesmereUIActionBars",        display = "Action Bars",         svName = "EllesmereUIActionBarsDB"        },
    { folder = "EllesmereUINameplates",        display = "Nameplates",          svName = "EllesmereUINameplatesDB"        },
    { folder = "EllesmereUIUnitFrames",        display = "Unit Frames",         svName = "EllesmereUIUnitFramesDB"        },
    { folder = "EllesmereUICooldownManager",   display = "Cooldown Manager",    svName = "EllesmereUICooldownManagerDB"   },
    { folder = "EllesmereUIResourceBars",      display = "Resource Bars",       svName = "EllesmereUIResourceBarsDB"      },
    { folder = "EllesmereUIAuraBuffReminders", display = "AuraBuff Reminders",  svName = "EllesmereUIAuraBuffRemindersDB" },
    -- v6.6 split-out addons (were previously bundled under EllesmereUIBasics).
    -- The old Basics entry is intentionally removed -- it's a shim with no
    -- user-visible profile data and listing it produced a misleading
    -- "Not included: Basics" warning on every imported v6.6+ profile.
    { folder = "EllesmereUIQoL",               display = "Quality of Life",     svName = "EllesmereUIQoLDB"               },
    { folder = "EllesmereUIBlizzardSkin",      display = "Blizz UI Enhanced",   svName = "EllesmereUIBlizzardSkinDB"      },
    { folder = "EllesmereUIFriends",           display = "Friends List",        svName = "EllesmereUIFriendsDB"           },
    { folder = "EllesmereUIMythicTimer",       display = "Mythic+ Timer",       svName = "EllesmereUIMythicTimerDB"       },
    { folder = "EllesmereUIQuestTracker",      display = "Quest Tracker",       svName = "EllesmereUIQuestTrackerDB"      },
    { folder = "EllesmereUIMinimap",           display = "Minimap",             svName = "EllesmereUIMinimapDB"           },
}
EllesmereUI._ADDON_DB_MAP = ADDON_DB_MAP

-------------------------------------------------------------------------------
--  Serializer: Lua table <-> string (no AceSerializer dependency)
--  Handles: string, number, boolean, nil, table (nested), color tables
-------------------------------------------------------------------------------
local Serializer = {}

local function SerializeValue(v, parts)
    local t = type(v)
    if t == "string" then
        parts[#parts + 1] = "s"
        -- Length-prefixed to avoid delimiter issues
        parts[#parts + 1] = #v
        parts[#parts + 1] = ":"
        parts[#parts + 1] = v
    elseif t == "number" then
        parts[#parts + 1] = "n"
        parts[#parts + 1] = tostring(v)
        parts[#parts + 1] = ";"
    elseif t == "boolean" then
        parts[#parts + 1] = v and "T" or "F"
    elseif t == "nil" then
        parts[#parts + 1] = "N"
    elseif t == "table" then
        parts[#parts + 1] = "{"
        -- Serialize array part first (integer keys 1..n)
        local n = #v
        for i = 1, n do
            SerializeValue(v[i], parts)
        end
        -- Then hash part (non-integer keys, or integer keys > n)
        for k, val in pairs(v) do
            local kt = type(k)
            if kt == "number" and k >= 1 and k <= n and k == math.floor(k) then
                -- Already serialized in array part
            else
                parts[#parts + 1] = "K"
                SerializeValue(k, parts)
                SerializeValue(val, parts)
            end
        end
        parts[#parts + 1] = "}"
    end
end

function Serializer.Serialize(tbl)
    local parts = {}
    SerializeValue(tbl, parts)
    return table.concat(parts)
end

-- Deserializer
local function DeserializeValue(str, pos)
    local tag = str:sub(pos, pos)
    if tag == "s" then
        -- Find the colon after the length
        local colonPos = str:find(":", pos + 1, true)
        if not colonPos then return nil, pos end
        local len = tonumber(str:sub(pos + 1, colonPos - 1))
        if not len then return nil, pos end
        local val = str:sub(colonPos + 1, colonPos + len)
        return val, colonPos + len + 1
    elseif tag == "n" then
        local semi = str:find(";", pos + 1, true)
        if not semi then return nil, pos end
        return tonumber(str:sub(pos + 1, semi - 1)), semi + 1
    elseif tag == "T" then
        return true, pos + 1
    elseif tag == "F" then
        return false, pos + 1
    elseif tag == "N" then
        return nil, pos + 1
    elseif tag == "{" then
        local tbl = {}
        local idx = 1
        local p = pos + 1
        while p <= #str do
            local c = str:sub(p, p)
            if c == "}" then
                return tbl, p + 1
            elseif c == "K" then
                -- Key-value pair
                local key, val
                key, p = DeserializeValue(str, p + 1)
                val, p = DeserializeValue(str, p)
                if key ~= nil then
                    tbl[key] = val
                end
            else
                -- Array element
                local val
                val, p = DeserializeValue(str, p)
                tbl[idx] = val
                idx = idx + 1
            end
        end
        return tbl, p
    end
    return nil, pos + 1
end

function Serializer.Deserialize(str)
    if not str or #str == 0 then return nil end
    local val, _ = DeserializeValue(str, 1)
    return val
end

EllesmereUI._Serializer = Serializer

-------------------------------------------------------------------------------
--  Deep copy utility
-------------------------------------------------------------------------------
local function DeepCopy(src, seen)
    if type(src) ~= "table" then return src end
    if seen and seen[src] then return seen[src] end
    if not seen then seen = {} end
    local copy = {}
    seen[src] = copy
    for k, v in pairs(src) do
        -- Skip frame references and other userdata that can't be serialized
        if type(v) ~= "userdata" and type(v) ~= "function" then
            copy[k] = DeepCopy(v, seen)
        end
    end
    return copy
end

local function DeepMerge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            DeepMerge(dst[k], v)
        else
            dst[k] = DeepCopy(v)
        end
    end
end

EllesmereUI._DeepCopy = DeepCopy




-------------------------------------------------------------------------------
--  Profile DB helpers
--  Profiles are stored in EllesmereUIDB.profiles = { [name] = profileData }
--  profileData = {
--      addons = { [folderName] = <snapshot of that addon's profile table> },
--      fonts  = <snapshot of EllesmereUIDB.fonts>,
--      customColors = <snapshot of EllesmereUIDB.customColors>,
--  }
--  EllesmereUIDB.activeProfile = "Default"  (name of active profile)
--  EllesmereUIDB.profileOrder  = { "Default", ... }
--  EllesmereUIDB.specProfiles  = { [specID] = "profileName" }
-------------------------------------------------------------------------------
local function GetProfilesDB()
    if not EllesmereUIDB then EllesmereUIDB = {} end
    if not EllesmereUIDB.profiles then EllesmereUIDB.profiles = {} end
    if not EllesmereUIDB.profileOrder then EllesmereUIDB.profileOrder = {} end
    if not EllesmereUIDB.specProfiles then EllesmereUIDB.specProfiles = {} end
    return EllesmereUIDB
end
EllesmereUI.GetProfilesDB = GetProfilesDB

-------------------------------------------------------------------------------
--  Anchor offset format conversion
--
--  Anchor offsets were originally stored relative to the target's center
--  (format version 0/nil). The current system stores them relative to
--  stable edges (format version 1):
--    TOP/BOTTOM: offsetX relative to target LEFT edge
--    LEFT/RIGHT: offsetY relative to target TOP edge
--
--- Check if an addon is loaded
local function IsAddonLoaded(name)
    if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(name) end
    if _G.IsAddOnLoaded then return _G.IsAddOnLoaded(name) end
    return false
end

--- Re-point all db.profile references to the given profile name.
--- Called when switching profiles so addons see the new data immediately.
local function RepointAllDBs(profileName)
    if not EllesmereUIDB.profiles then EllesmereUIDB.profiles = {} end
    if type(EllesmereUIDB.profiles[profileName]) ~= "table" then
        EllesmereUIDB.profiles[profileName] = {}
    end
    local profileData = EllesmereUIDB.profiles[profileName]
    if not profileData.addons then profileData.addons = {} end

    -- Sync: copy synced module data from outgoing profile to incoming.
    -- activeProfile is already set to the new name by callers, so read
    -- the outgoing profile from the db registry (not yet re-pointed).
    local sm = EllesmereUIDB.syncedModules
    if sm then
        local reg = EllesmereUI.Lite and EllesmereUI.Lite._dbRegistry
        local outName = reg and reg[1] and reg[1]._profileName or "Default"
        local outProf = EllesmereUIDB.profiles[outName]
        if outProf and outProf.addons and outName ~= profileName then
            for folder, synced in pairs(sm) do
                if synced and outProf.addons[folder] then
                    profileData.addons[folder] = DeepCopy(outProf.addons[folder])
                end
            end
        end
    end

    local registry = EllesmereUI.Lite and EllesmereUI.Lite._dbRegistry
    if not registry then return end
    for _, db in ipairs(registry) do
        local folder = db.folder
        if folder then
            if type(profileData.addons[folder]) ~= "table" then
                profileData.addons[folder] = {}
            end
            db.profile = profileData.addons[folder]
            db._profileName = profileName
            -- Re-merge defaults so new profile has all keys
            if db._profileDefaults then
                EllesmereUI.Lite.DeepMergeDefaults(db.profile, db._profileDefaults)
            end
        end
    end
    -- Restore unlock layout from the profile.
    -- If the profile has no unlockLayout yet (e.g. created before this key
    -- existed), leave the live unlock data untouched so the current
    -- positions are preserved. Only restore when the profile explicitly
    -- contains layout data from a previous save.
    local ul = profileData.unlockLayout
    if ul then
        EllesmereUIDB.unlockAnchors     = DeepCopy(ul.anchors      or {})
        EllesmereUIDB.unlockWidthMatch  = DeepCopy(ul.widthMatch   or {})
        EllesmereUIDB.unlockHeightMatch = DeepCopy(ul.heightMatch  or {})
        EllesmereUIDB.phantomBounds     = DeepCopy(ul.phantomBounds or {})
    end
    -- Seed castbar anchor defaults ONLY on brand-new profiles (no unlockLayout
    -- yet). Re-seeding every load would clobber a user's deliberate un-anchor
    -- or manual position with the default "target BOTTOM" anchor the next
    -- time the profile is applied (e.g. via spec profile assignment).
    if not ul then
        local anchors = EllesmereUIDB.unlockAnchors
        local wMatch  = EllesmereUIDB.unlockWidthMatch
        if anchors and wMatch then
            local CB_DEFAULTS = {
                { cb = "playerCastbar", parent = "player" },
                { cb = "targetCastbar", parent = "target" },
                { cb = "focusCastbar",  parent = "focus" },
            }
            for _, def in ipairs(CB_DEFAULTS) do
                if not anchors[def.cb] then
                    anchors[def.cb] = { target = def.parent, side = "BOTTOM" }
                end
                if not wMatch[def.cb] then
                    wMatch[def.cb] = def.parent
                end
            end
        end
    end
    -- Restore fonts and custom colors from the profile
    if profileData.fonts then
        local fontsDB = EllesmereUI.GetFontsDB()
        for k in pairs(fontsDB) do fontsDB[k] = nil end
        for k, v in pairs(profileData.fonts) do fontsDB[k] = DeepCopy(v) end
        if fontsDB.global      == nil then fontsDB.global      = "Expressway" end
        if fontsDB.outlineMode == nil then fontsDB.outlineMode = "shadow"     end
    end
    if profileData.customColors then
        local colorsDB = EllesmereUI.GetCustomColorsDB()
        for k in pairs(colorsDB) do colorsDB[k] = nil end
        for k, v in pairs(profileData.customColors) do colorsDB[k] = DeepCopy(v) end
    end
end

-------------------------------------------------------------------------------
--  ResolveSpecProfile
--
--  Single authoritative function that resolves the current spec's target
--  profile name. Used by both PreSeedSpecProfile (before OnEnable) and the
--  runtime spec event handler.
--
--  Resolution order:
--    1. Cached spec from lastSpecByChar (reliable across sessions)
--    2. Live GetSpecialization() API (available after ADDON_LOADED for
--       returning characters, may be nil for brand-new characters)
--
--  Returns: targetProfileName, resolvedSpecID, charKey  -- or nil if no
--           spec assignment exists or spec cannot be resolved yet.
-------------------------------------------------------------------------------
local function ResolveSpecProfile()
    if not EllesmereUIDB then return nil end
    local specProfiles = EllesmereUIDB.specProfiles
    if not specProfiles or not next(specProfiles) then return nil end

    local charKey = UnitName("player") .. " - " .. GetRealmName()
    if not EllesmereUIDB.lastSpecByChar then
        EllesmereUIDB.lastSpecByChar = {}
    end

    -- Prefer cached spec from last session (always reliable)
    local resolvedSpecID = EllesmereUIDB.lastSpecByChar[charKey]

    -- Fall back to live API if no cached value
    if not resolvedSpecID then
        local specIdx = GetSpecialization and GetSpecialization()
        if specIdx and specIdx > 0 then
            local liveSpecID = GetSpecializationInfo(specIdx)
            if liveSpecID then
                resolvedSpecID = liveSpecID
                EllesmereUIDB.lastSpecByChar[charKey] = resolvedSpecID
            end
        end
    end

    if not resolvedSpecID then return nil end

    local targetProfile = specProfiles[resolvedSpecID]
    if not targetProfile then return nil end

    local profiles = EllesmereUIDB.profiles
    if not profiles or not profiles[targetProfile] then return nil end

    return targetProfile, resolvedSpecID, charKey
end

-------------------------------------------------------------------------------
--  Spec profile pre-seed
--
--  Runs once just before child addon OnEnable calls, after all OnInitialize
--  calls have completed (so all NewDB calls have run).
--  At this point the spec API is available, so we can resolve the current
--  spec and re-point all db.profile references to the correct profile table
--  in the central store before any addon builds its UI.
--
--  This is the sole pre-OnEnable resolution point. NewDB reads activeProfile
--  as-is (defaults to "Default" or whatever was saved from last session).
-------------------------------------------------------------------------------

--- Called by EllesmereUI_Lite just before child addon OnEnable calls fire.
--- Uses ResolveSpecProfile() to determine the correct profile, then
--- re-points all db.profile references via RepointAllDBs.
function EllesmereUI.PreSeedSpecProfile()
    local targetProfile, resolvedSpecID = ResolveSpecProfile()
    if not targetProfile then
        -- No spec assignment resolved; lock auto-save if spec profiles exist
        if EllesmereUIDB and EllesmereUIDB.specProfiles and next(EllesmereUIDB.specProfiles) then
            EllesmereUI._profileSaveLocked = true
        end
        return
    end

    EllesmereUIDB.activeProfile = targetProfile
    RepointAllDBs(targetProfile)
    EllesmereUI._preSeedComplete = true
end

--- Get the live profile table for an addon.
--- All addons use _dbRegistry (which points into
--- EllesmereUIDB.profiles[active].addons[folder]).
local function GetAddonProfile(entry)
    if EllesmereUI.Lite and EllesmereUI.Lite._dbRegistry then
        for _, db in ipairs(EllesmereUI.Lite._dbRegistry) do
            if db.folder == entry.folder then
                return db.profile
            end
        end
    end
    return nil
end

--- Snapshot the current state of all loaded addons into a profile data table
function EllesmereUI.SnapshotAllAddons()
    local data = { addons = {} }
    for _, entry in ipairs(ADDON_DB_MAP) do
        if IsAddonLoaded(entry.folder) then
            local profile = GetAddonProfile(entry)
            if profile then
                data.addons[entry.folder] = DeepCopy(profile)
            end
        end
    end
    -- Include global font and color settings
    data.fonts = DeepCopy(EllesmereUI.GetFontsDB())
    local cc = EllesmereUI.GetCustomColorsDB()
    data.customColors = DeepCopy(cc)
    -- Include unlock mode layout data (anchors, size matches)
    if EllesmereUIDB then
        data.unlockLayout = {
            anchors       = DeepCopy(EllesmereUIDB.unlockAnchors     or {}),
            widthMatch    = DeepCopy(EllesmereUIDB.unlockWidthMatch  or {}),
            heightMatch   = DeepCopy(EllesmereUIDB.unlockHeightMatch or {}),
            phantomBounds = DeepCopy(EllesmereUIDB.phantomBounds     or {}),
        }
    end
    return data
end

--[[ ADDON-SPECIFIC EXPORT DISABLED
--- Snapshot a single addon's profile
function EllesmereUI.SnapshotAddon(folderName)
    for _, entry in ipairs(ADDON_DB_MAP) do
        if entry.folder == folderName and IsAddonLoaded(folderName) then
            local profile = GetAddonProfile(entry)
            if profile then return DeepCopy(profile) end
        end
    end
    return nil
end

--- Snapshot multiple addons (for multi-addon export)
function EllesmereUI.SnapshotAddons(folderList)
    local data = { addons = {} }
    for _, folderName in ipairs(folderList) do
        for _, entry in ipairs(ADDON_DB_MAP) do
            if entry.folder == folderName and IsAddonLoaded(folderName) then
                local profile = GetAddonProfile(entry)
                if profile then
                    data.addons[folderName] = DeepCopy(profile)
                end
                break
            end
        end
    end
    -- Always include fonts and colors
    data.fonts = DeepCopy(EllesmereUI.GetFontsDB())
    data.customColors = DeepCopy(EllesmereUI.GetCustomColorsDB())
    -- Include unlock mode layout data
    if EllesmereUIDB then
        data.unlockLayout = {
            anchors       = DeepCopy(EllesmereUIDB.unlockAnchors     or {}),
            widthMatch    = DeepCopy(EllesmereUIDB.unlockWidthMatch  or {}),
            heightMatch   = DeepCopy(EllesmereUIDB.unlockHeightMatch or {}),
            phantomBounds = DeepCopy(EllesmereUIDB.phantomBounds     or {}),
        }
    end
    return data
end
--]] -- END ADDON-SPECIFIC EXPORT DISABLED

--- Apply imported profile data into the live db.profile tables.
--- Used by import to write external data into the active profile.
--- For normal profile switching, use SwitchProfile (which calls RepointAllDBs).
function EllesmereUI.ApplyProfileData(profileData)
    if not profileData or not profileData.addons then return end

    -- Build a folder -> db lookup from the Lite registry
    local dbByFolder = {}
    if EllesmereUI.Lite and EllesmereUI.Lite._dbRegistry then
        for _, db in ipairs(EllesmereUI.Lite._dbRegistry) do
            if db.folder then dbByFolder[db.folder] = db end
        end
    end

    for _, entry in ipairs(ADDON_DB_MAP) do
        local snap = profileData.addons[entry.folder]
        if snap and IsAddonLoaded(entry.folder) then
            local db = dbByFolder[entry.folder]
            if db then
                local profile = db.profile
                -- TBB and barGlows are spec-specific (in spellAssignments),
                -- not in profile. No save/restore needed on profile switch.
                for k in pairs(profile) do profile[k] = nil end
                for k, v in pairs(snap) do profile[k] = DeepCopy(v) end
                if db._profileDefaults then
                    EllesmereUI.Lite.DeepMergeDefaults(profile, db._profileDefaults)
                end
                -- Ensure per-unit bg colors are never nil after import
                if entry.folder == "EllesmereUIUnitFrames" then
                    local UF_UNITS = { "player", "target", "focus", "boss", "pet", "totPet" }
                    local DEF_BG = 17/255
                    for _, uKey in ipairs(UF_UNITS) do
                        local s = profile[uKey]
                        if s and s.customBgColor == nil then
                            s.customBgColor = { r = DEF_BG, g = DEF_BG, b = DEF_BG }
                        end
                    end
                end
            end
        end
    end
    -- Apply fonts and colors
    do
        local fontsDB = EllesmereUI.GetFontsDB()
        for k in pairs(fontsDB) do fontsDB[k] = nil end
        if profileData.fonts then
            for k, v in pairs(profileData.fonts) do fontsDB[k] = DeepCopy(v) end
        end
        if fontsDB.global      == nil then fontsDB.global      = "Expressway" end
        if fontsDB.outlineMode == nil then fontsDB.outlineMode = "shadow"     end
    end
    do
        local colorsDB = EllesmereUI.GetCustomColorsDB()
        for k in pairs(colorsDB) do colorsDB[k] = nil end
        if profileData.customColors then
            for k, v in pairs(profileData.customColors) do colorsDB[k] = DeepCopy(v) end
        end
    end
    -- Restore unlock mode layout data
    if EllesmereUIDB then
        local ul = profileData.unlockLayout
        if ul then
            EllesmereUIDB.unlockAnchors     = DeepCopy(ul.anchors      or {})
            EllesmereUIDB.unlockWidthMatch  = DeepCopy(ul.widthMatch   or {})
            EllesmereUIDB.unlockHeightMatch = DeepCopy(ul.heightMatch  or {})
            EllesmereUIDB.phantomBounds     = DeepCopy(ul.phantomBounds or {})
        end
        -- If profile predates unlockLayout, leave live data untouched
    end
end

--- Trigger live refresh on all loaded addons after a profile apply.
function EllesmereUI.RefreshAllAddons()
    -- ResourceBars (full rebuild)
    if _G._ERB_Apply then _G._ERB_Apply() end
    -- CDM: skip during spec-profile switch. CDM's SPELLS_CHANGED handler
    -- will detect the spec key mismatch and rebuild with the correct spec.
    -- Running it here would race with that rebuild.
    if not EllesmereUI._specProfileSwitching then
        if _G._ECME_LoadSpecProfile and _G._ECME_GetCurrentSpecKey then
            local curKey = _G._ECME_GetCurrentSpecKey()
            if curKey then _G._ECME_LoadSpecProfile(curKey) end
        end
        if _G._ECME_Apply then _G._ECME_Apply() end
    end
    -- Cursor (style + position)
    if _G._ECL_Apply then _G._ECL_Apply() end
    if _G._ECL_ApplyTrail then _G._ECL_ApplyTrail() end
    if _G._ECL_ApplyGCDCircle then _G._ECL_ApplyGCDCircle() end
    if _G._ECL_ApplyCastCircle then _G._ECL_ApplyCastCircle() end
    -- AuraBuffReminders (refresh + position)
    if _G._EABR_RequestRefresh then _G._EABR_RequestRefresh() end
    if _G._EABR_ApplyUnlockPos then _G._EABR_ApplyUnlockPos() end
    -- ActionBars (style + layout + position)
    if _G._EAB_Apply then _G._EAB_Apply() end
    -- UnitFrames (style + layout + position)
    if _G._EUF_ReloadFrames then _G._EUF_ReloadFrames() end
    -- Nameplates
    if _G._ENP_RefreshAllSettings then _G._ENP_RefreshAllSettings() end
    -- Quest Tracker
    if _G._EQT_RefreshAll then _G._EQT_RefreshAll() end
    -- Chat (sidebar icons, borders, fonts, visibility)
    if _G._ECHAT_RefreshAll then _G._ECHAT_RefreshAll() end
    -- Friends List
    if _G._EFR_ApplyFriends then _G._EFR_ApplyFriends() end
    -- Mythic Timer
    if _G._EMT_Apply then _G._EMT_Apply() end
    -- Dragon Riding HUD
    if _G._EDR_Rebuild then _G._EDR_Rebuild() end
    -- Minimap (flyout button state)
    if _G._EMIN_RefreshFlyout then _G._EMIN_RefreshFlyout() end
    -- Global class/power colors (updates oUF, nameplates, raid frames)
    if EllesmereUI.ApplyColorsToOUF then EllesmereUI.ApplyColorsToOUF() end
    -- Re-register unlock elements for all modules whose bar sets can
    -- differ between profiles. Without this, _applySavedPositions uses
    -- stale registrations from the outgoing profile and anchors fail
    -- for elements that only exist in the incoming profile (they land
    -- at CENTER/CENTER = screen center).
    if _G._ECME_RegisterUnlock then _G._ECME_RegisterUnlock() end
    if _G._ECME_RegisterTBBUnlock then _G._ECME_RegisterTBBUnlock() end
    if _G._ERB_RegisterUnlock then _G._ERB_RegisterUnlock() end
    if _G._EABR_RegisterUnlock then _G._EABR_RegisterUnlock() end
    if _G._ECL_RegisterUnlock then _G._ECL_RegisterUnlock() end
    if _G._EUI_BattleRes_RegisterUnlock then _G._EUI_BattleRes_RegisterUnlock() end
    -- After all addons have rebuilt and positioned their frames from
    -- db.profile.positions, re-apply centralized grow-direction positioning
    -- (handles lazy migration of imported TOPLEFT positions to CENTER format)
    -- and resync anchor offsets so the anchor relationships stay correct for
    -- future drags. Triple-deferred so it runs AFTER debounced rebuilds have
    -- completed and frames are at final positions.
    -- Position re-application and anchor resync are deferred to
    -- OnSpecSwitchComplete (if spec switching) or run inline here
    -- for non-spec profile switches (manual switch from options).
    if not EllesmereUI._specProfileSwitching then
        C_Timer.After(0, function()
            C_Timer.After(0, function()
                if EllesmereUI._applySavedPositions then
                    EllesmereUI._applySavedPositions()
                end
                if EllesmereUI.ResyncAnchorOffsets then
                    EllesmereUI.ResyncAnchorOffsets()
                end
            end)
        end)
    end
    -- If CDM is loaded, it calls OnSpecSwitchComplete from ProcessSpecChange
    -- after its SPELLS_CHANGED rebuild finishes. If CDM is NOT loaded,
    -- complete immediately since there's nothing to wait for.
    local cdmLoaded = C_AddOns and C_AddOns.IsAddOnLoaded
        and C_AddOns.IsAddOnLoaded("EllesmereUICooldownManager")
    if not cdmLoaded then
        EllesmereUI.OnSpecSwitchComplete()
    end
end

--- Called by CDM (or RefreshAllAddons if CDM not loaded) when the spec
--- switch rebuild is fully settled. Clears the suppression flag and
--- re-applies width/height matches so all matched frames pick up
--- the new profile dimensions.
function EllesmereUI.OnSpecSwitchComplete()
    EllesmereUI._specProfileSwitching = false
    if EllesmereUI.ApplyAllWidthHeightMatches then
        EllesmereUI.ApplyAllWidthHeightMatches()
    end
    if EllesmereUI._applySavedPositions then
        EllesmereUI._applySavedPositions()
    end
    if EllesmereUI.ResyncAnchorOffsets then
        EllesmereUI.ResyncAnchorOffsets()
    end
end

-------------------------------------------------------------------------------
--  Profile Keybinds
--  Each profile can have a key bound to switch to it instantly.
--  Stored in EllesmereUIDB.profileKeybinds = { ["Name"] = "CTRL-1", ... }
--  Uses hidden buttons + SetOverrideBindingClick, same pattern as Party Mode.
-------------------------------------------------------------------------------
local _profileBindBtns = {} -- [profileName] = hidden Button

local function GetProfileKeybinds()
    if not EllesmereUIDB then EllesmereUIDB = {} end
    if not EllesmereUIDB.profileKeybinds then EllesmereUIDB.profileKeybinds = {} end
    return EllesmereUIDB.profileKeybinds
end

local function EnsureProfileBindBtn(profileName)
    if _profileBindBtns[profileName] then return _profileBindBtns[profileName] end
    local safeName = profileName:gsub("[^%w]", "")
    local btn = CreateFrame("Button", "EllesmereUIProfileBind_" .. safeName, UIParent)
    btn:Hide()
    btn:SetScript("OnClick", function()
        local active = EllesmereUI.GetActiveProfileName()
        if active == profileName then return end
        local _, profiles = EllesmereUI.GetProfileList()
        local fontWillChange = EllesmereUI.ProfileChangesFont(profiles and profiles[profileName])
        EllesmereUI.SwitchProfile(profileName)
        EllesmereUI.RefreshAllAddons()
        if fontWillChange then
            EllesmereUI:ShowConfirmPopup({
                title       = "Reload Required",
                message     = "Font changed. A UI reload is needed to apply the new font.",
                confirmText = "Reload Now",
                cancelText  = "Later",
                onConfirm   = function() ReloadUI() end,
            })
        else
            EllesmereUI:RefreshPage()
        end
    end)
    _profileBindBtns[profileName] = btn
    return btn
end

function EllesmereUI.SetProfileKeybind(profileName, key)
    local kb = GetProfileKeybinds()
    -- Clear old binding for this profile
    local oldKey = kb[profileName]
    local btn = EnsureProfileBindBtn(profileName)
    if oldKey then
        ClearOverrideBindings(btn)
    end
    if key then
        kb[profileName] = key
        SetOverrideBindingClick(btn, true, key, btn:GetName())
    else
        kb[profileName] = nil
    end
end

function EllesmereUI.GetProfileKeybind(profileName)
    local kb = GetProfileKeybinds()
    return kb[profileName]
end

--- Called on login to restore all saved profile keybinds
function EllesmereUI.RestoreProfileKeybinds()
    local kb = GetProfileKeybinds()
    for profileName, key in pairs(kb) do
        if key then
            local btn = EnsureProfileBindBtn(profileName)
            SetOverrideBindingClick(btn, true, key, btn:GetName())
        end
    end
end

--- Update keybind references when a profile is renamed
function EllesmereUI.OnProfileRenamed(oldName, newName)
    local kb = GetProfileKeybinds()
    local key = kb[oldName]
    if key then
        local oldBtn = _profileBindBtns[oldName]
        if oldBtn then ClearOverrideBindings(oldBtn) end
        _profileBindBtns[oldName] = nil
        kb[oldName] = nil
        kb[newName] = key
        local newBtn = EnsureProfileBindBtn(newName)
        SetOverrideBindingClick(newBtn, true, key, newBtn:GetName())
    end
end

--- Clean up keybind when a profile is deleted
function EllesmereUI.OnProfileDeleted(profileName)
    local kb = GetProfileKeybinds()
    if kb[profileName] then
        local btn = _profileBindBtns[profileName]
        if btn then ClearOverrideBindings(btn) end
        _profileBindBtns[profileName] = nil
        kb[profileName] = nil
    end
end

--- Returns true if applying profileData would change the global font or outline mode.
--- Used to decide whether to show a reload popup after a profile switch.
function EllesmereUI.ProfileChangesFont(profileData)
    if not profileData or not profileData.fonts then return false end
    local cur = EllesmereUI.GetFontsDB()
    local curFont    = cur.global      or "Expressway"
    local curOutline = cur.outlineMode or "shadow"
    local newFont    = profileData.fonts.global      or "Expressway"
    local newOutline = profileData.fonts.outlineMode or "shadow"
    -- "none" and "shadow" are both drop-shadow (no outline) -- treat as identical
    if curOutline == "none" then curOutline = "shadow" end
    if newOutline == "none" then newOutline = "shadow" end
    return curFont ~= newFont or curOutline ~= newOutline
end

--[[ ADDON-SPECIFIC EXPORT DISABLED
--- Apply a partial profile (specific addons only) by merging into active
function EllesmereUI.ApplyPartialProfile(profileData)
    if not profileData or not profileData.addons then return end
    for folderName, snap in pairs(profileData.addons) do
        for _, entry in ipairs(ADDON_DB_MAP) do
            if entry.folder == folderName and IsAddonLoaded(folderName) then
                local profile = GetAddonProfile(entry)
                if profile then
                    for k, v in pairs(snap) do
                        profile[k] = DeepCopy(v)
                    end
                end
                break
            end
        end
    end
    -- Always apply fonts and colors if present
    if profileData.fonts then
        local fontsDB = EllesmereUI.GetFontsDB()
        for k, v in pairs(profileData.fonts) do
            fontsDB[k] = DeepCopy(v)
        end
    end
    if profileData.customColors then
        local colorsDB = EllesmereUI.GetCustomColorsDB()
        for k, v in pairs(profileData.customColors) do
            colorsDB[k] = DeepCopy(v)
        end
    end
end
--]] -- END ADDON-SPECIFIC EXPORT DISABLED

-------------------------------------------------------------------------------
--  Export / Import
--  Format: !EUI_<base64 encoded compressed serialized data>
--  The data table contains:
--    { version = 3, type = "full"|"partial", data = profileData }
-------------------------------------------------------------------------------
local EXPORT_PREFIX = "!EUI_"

function EllesmereUI.ExportProfile(profileName)
    local db = GetProfilesDB()
    local profileData = db.profiles[profileName]
    if not profileData then return nil end
    -- If exporting the active profile, ensure fonts/colors/layout are current
    if profileName == (db.activeProfile or "Default") then
        profileData.fonts = DeepCopy(EllesmereUI.GetFontsDB())
        profileData.customColors = DeepCopy(EllesmereUI.GetCustomColorsDB())
        profileData.unlockLayout = {
            anchors       = DeepCopy(EllesmereUIDB.unlockAnchors     or {}),
            widthMatch    = DeepCopy(EllesmereUIDB.unlockWidthMatch  or {}),
            heightMatch   = DeepCopy(EllesmereUIDB.unlockHeightMatch or {}),
            phantomBounds = DeepCopy(EllesmereUIDB.phantomBounds     or {}),
        }
    end
    local exportData = DeepCopy(profileData)
    -- Exclude spec-specific data from export
    exportData.trackedBuffBars = nil
    exportData.tbbPositions = nil
    -- CDM spell assignments are NOT exported -- users share spell layouts
    -- via Blizzard's built-in CDM sharing system instead.
    exportData.spellAssignments = nil
    local payload = { version = 3, type = "full", data = exportData }
    local serialized = Serializer.Serialize(payload)
    if not LibDeflate then return nil end
    local compressed = LibDeflate:CompressDeflate(serialized)
    local encoded = LibDeflate:EncodeForPrint(compressed)
    return EXPORT_PREFIX .. encoded
end

--[[ ADDON-SPECIFIC EXPORT DISABLED
function EllesmereUI.ExportAddons(folderList)
    local profileData = EllesmereUI.SnapshotAddons(folderList)
    local sw, sh = GetPhysicalScreenSize()
    local euiScale = EllesmereUIDB and EllesmereUIDB.ppUIScale or (UIParent and UIParent:GetScale()) or 1
    local meta = {
        euiScale = euiScale,
        screenW  = sw and math.floor(sw) or 0,
        screenH  = sh and math.floor(sh) or 0,
    }
    local payload = { version = 3, type = "partial", data = profileData, meta = meta }
    local serialized = Serializer.Serialize(payload)
    if not LibDeflate then return nil end
    local compressed = LibDeflate:CompressDeflate(serialized)
    local encoded = LibDeflate:EncodeForPrint(compressed)
    return EXPORT_PREFIX .. encoded
end
--]] -- END ADDON-SPECIFIC EXPORT DISABLED

-------------------------------------------------------------------------------
--  CDM spec profile helpers for export/import spec picker
-------------------------------------------------------------------------------

--- Get info about which specs have data in the CDM specProfiles table.
--- Returns: { { key="250", name="Blood", icon=..., hasData=true }, ... }
--- Includes ALL specs for the player's class, with hasData indicating
--- whether specProfiles contains data for that spec.
function EllesmereUI.GetCDMSpecInfo()
    local sa = EllesmereUIDB and EllesmereUIDB.spellAssignments
    local specProfiles = sa and sa.specProfiles or {}
    local result = {}
    local numSpecs = GetNumSpecializations and GetNumSpecializations() or 0
    for i = 1, numSpecs do
        local specID, sName, _, sIcon = GetSpecializationInfo(i)
        if specID then
            local key = tostring(specID)
            result[#result + 1] = {
                key     = key,
                name    = sName or ("Spec " .. key),
                icon    = sIcon,
                hasData = specProfiles[key] ~= nil,
            }
        end
    end
    return result
end

--- Filter specProfiles in an export snapshot to only include selected specs.
--- Reads from snapshot.spellAssignments (the dedicated store copy on the payload).
--- Modifies the snapshot in-place. selectedSpecs = { ["250"] = true, ... }
function EllesmereUI.FilterExportSpecProfiles(snapshot, selectedSpecs)
    if not snapshot or not snapshot.spellAssignments then return end
    local sp = snapshot.spellAssignments.specProfiles
    if not sp then return end
    for key in pairs(sp) do
        if not selectedSpecs[key] then
            sp[key] = nil
        end
    end
end

--- After a profile import, apply only selected specs' specProfiles from the
--- imported data into the dedicated spell assignment store.
--- importedSpellAssignments = the spellAssignments object from the import payload.
--- selectedSpecs = { ["250"] = true, ... }
function EllesmereUI.ApplyImportedSpecProfiles(importedSpellAssignments, selectedSpecs)
    if not importedSpellAssignments or not importedSpellAssignments.specProfiles then return end
    if not EllesmereUIDB.spellAssignments then
        EllesmereUIDB.spellAssignments = { specProfiles = {} }
    end
    local sa = EllesmereUIDB.spellAssignments
    if not sa.specProfiles then sa.specProfiles = {} end
    for key, data in pairs(importedSpellAssignments.specProfiles) do
        if selectedSpecs[key] then
            sa.specProfiles[key] = DeepCopy(data)
        end
    end
    -- If the current spec was imported, reload it live
    if _G._ECME_GetCurrentSpecKey and _G._ECME_LoadSpecProfile then
        local currentKey = _G._ECME_GetCurrentSpecKey()
        if currentKey and selectedSpecs[currentKey] then
            _G._ECME_LoadSpecProfile(currentKey)
        end
    end
end

--- Get the list of spec keys that have data in imported spell assignments.
--- Returns same format as GetCDMSpecInfo but based on imported data.
--- Accepts either the new spellAssignments format or legacy CDM snapshot.
function EllesmereUI.GetImportedCDMSpecInfo(importedSpellAssignments)
    if not importedSpellAssignments then return {} end
    -- Support both new format (spellAssignments.specProfiles) and legacy (cdmSnap.specProfiles)
    local specProfiles = importedSpellAssignments.specProfiles
    if not specProfiles then return {} end
    local result = {}
    for specKey in pairs(specProfiles) do
        local specID = tonumber(specKey)
        local name, icon
        if specID and specID > 0 and GetSpecializationInfoByID then
            local _, sName, _, sIcon = GetSpecializationInfoByID(specID)
            name = sName
            icon = sIcon
        end
        result[#result + 1] = {
            key     = specKey,
            name    = name or ("Spec " .. specKey),
            icon    = icon,
            hasData = true,
        }
    end
    table.sort(result, function(a, b) return a.key < b.key end)
    return result
end

-------------------------------------------------------------------------------
--  CDM Spec Picker Popup
--  Thin wrapper around ShowSpecAssignPopup for CDM export/import.
--
--  opts = {
--      title    = string,
--      subtitle = string,
--      confirmText = string (button label),
--      specs    = { { key, name, icon, hasData, checked }, ... },
--      onConfirm = function(selectedSpecs)  -- { ["250"]=true, ... }
--      onCancel  = function() (optional)
--  }
--  specs[i].hasData = false grays out the row and shows disabled tooltip.
--  specs[i].checked = initial checked state (only for hasData=true rows).
-------------------------------------------------------------------------------
do
    -- Dummy db/dbKey/presetKey for the assignments table
    local dummyDB = { _cdmPick = { _cdm = {} } }

    function EllesmereUI:ShowCDMSpecPickerPopup(opts)
        local specs = opts.specs or {}

        -- Reset assignments
        dummyDB._cdmPick._cdm = {}

        -- Pre-check specs that have data; all specs remain selectable
        local preCheckedSpecs = {}
        for _, sp in ipairs(specs) do
            local numID = tonumber(sp.key)
            if numID and sp.checked then
                preCheckedSpecs[numID] = true
            end
        end

        EllesmereUI:ShowSpecAssignPopup({
            db              = dummyDB,
            dbKey           = "_cdmPick",
            presetKey       = "_cdm",
            title           = opts.title,
            subtitle        = opts.subtitle,
            buttonText      = opts.confirmText or "Confirm",
            disabledSpecs   = {},
            preCheckedSpecs = preCheckedSpecs,
            onConfirm       = opts.onConfirm and function(assignments)
                -- Convert numeric specID assignments back to string keys
                local selected = {}
                for specID in pairs(assignments) do
                    selected[tostring(specID)] = true
                end
                opts.onConfirm(selected)
            end,
            onCancel        = opts.onCancel,
        })
    end
end

function EllesmereUI.ExportCurrentProfile()
    local profileData = EllesmereUI.SnapshotAllAddons()
    -- CDM spell assignments are NOT exported -- users share spell layouts
    -- via Blizzard's built-in CDM sharing system instead.
    profileData.spellAssignments = nil
    local sw, sh = GetPhysicalScreenSize()
    -- Use EllesmereUI's own stored scale (UIParent scale), not Blizzard's CVar
    local euiScale = EllesmereUIDB and EllesmereUIDB.ppUIScale or (UIParent and UIParent:GetScale()) or 1
    local meta = {
        euiScale = euiScale,
        screenW  = sw and math.floor(sw) or 0,
        screenH  = sh and math.floor(sh) or 0,
    }
    local payload = { version = 3, type = "full", data = profileData, meta = meta }
    local serialized = Serializer.Serialize(payload)
    if not LibDeflate then return nil end
    local compressed = LibDeflate:CompressDeflate(serialized)
    local encoded = LibDeflate:EncodeForPrint(compressed)
    return EXPORT_PREFIX .. encoded
end

function EllesmereUI.DecodeImportString(importStr)
    if not importStr or #importStr < 5 then return nil, "Invalid string" end
    -- Detect old CDM bar layout strings (format removed in 5.1.2)
    if importStr:sub(1, 9) == "!EUICDM_" then
        return nil, "This is an old CDM Bar Layout string. This format is no longer supported. Use the standard profile import instead."
    end
    if importStr:sub(1, #EXPORT_PREFIX) ~= EXPORT_PREFIX then
        return nil, "Not a valid EllesmereUI string. Make sure you copied the entire string."
    end
    if not LibDeflate then return nil, "LibDeflate not available" end
    local encoded = importStr:sub(#EXPORT_PREFIX + 1)
    local decoded = LibDeflate:DecodeForPrint(encoded)
    if not decoded then return nil, "Failed to decode string" end
    local decompressed = LibDeflate:DecompressDeflate(decoded)
    if not decompressed then return nil, "Failed to decompress data" end
    local payload = Serializer.Deserialize(decompressed)
    if not payload or type(payload) ~= "table" then
        return nil, "Failed to deserialize data"
    end
    if not payload.version or payload.version < 3 then
        return nil, "This profile was created before the beta wipe and is no longer compatible. Please create a new export."
    end
    if payload.version > 3 then
        return nil, "This profile was created with a newer version of EllesmereUI. Please update your addon."
    end
    return payload, nil
end

--- Reset class-dependent fill colors in Resource Bars after a profile import.
--- The exporter's class color may be baked into fillR/fillG/fillB; this
--- resets them to the importer's own class/power colors and clears
--- customColored so the bars use runtime class color lookup.
local function FixupImportedClassColors()
    local rbEntry
    for _, e in ipairs(ADDON_DB_MAP) do
        if e.folder == "EllesmereUIResourceBars" then rbEntry = e; break end
    end
    if not rbEntry or not IsAddonLoaded(rbEntry.folder) then return end
    local profile = GetAddonProfile(rbEntry)
    if not profile then return end

    local _, classFile = UnitClass("player")
    -- CLASS_COLORS and POWER_COLORS are local to ResourceBars, so we
    -- use the same lookup the addon uses at init time.
    local classColors = EllesmereUI.CLASS_COLOR_MAP
    local cc = classColors and classColors[classFile]

    -- Health bar: reset to importer's class color
    if profile.health and not profile.health.darkTheme then
        profile.health.customColored = false
        if cc then
            profile.health.fillR = cc.r
            profile.health.fillG = cc.g
            profile.health.fillB = cc.b
        end
    end
end

--- Import a profile string. Returns: success, errorMsg
--- The caller must provide a name for the new profile.
function EllesmereUI.ImportProfile(importStr, profileName)
    local payload, err = EllesmereUI.DecodeImportString(importStr)
    if not payload then return false, err end

    local db = GetProfilesDB()

    if payload.type == "cdm_spells" then
        return false, "This is a CDM Bar Layout string, not a profile string."
    end

    -- Check if current spec has an assigned profile (blocks auto-apply)
    local specLocked = false
    do
        local si = GetSpecialization and GetSpecialization() or 0
        local sid = si and si > 0 and GetSpecializationInfo(si) or nil
        if sid then
            local assigned = db.specProfiles and db.specProfiles[sid]
            if assigned then specLocked = true end
        end
    end

    if payload.type == "full" then
        -- Full profile: store as a new named profile
        local stored = DeepCopy(payload.data)
        -- Strip spell assignment data from stored profile (lives in dedicated store)
        if stored.addons and stored.addons["EllesmereUICooldownManager"] then
            stored.addons["EllesmereUICooldownManager"].specProfiles = nil
            stored.addons["EllesmereUICooldownManager"].barGlows = nil
        end
        stored.spellAssignments = nil
        -- Snap all positions to the physical pixel grid (imported profiles
        -- may come from a different version without pixel snapping)
        if EllesmereUI.SnapProfilePositions then
            EllesmereUI.SnapProfilePositions(stored)
        end
        db.profiles[profileName] = stored
        -- Add to order if not present
        local found = false
        for _, n in ipairs(db.profileOrder) do
            if n == profileName then found = true; break end
        end
        if not found then
            table.insert(db.profileOrder, 1, profileName)
        end
        -- CDM spell assignments are NOT written here. The caller shows
        -- a spec picker popup that lets the user choose which specs to
        -- import, then calls ApplyImportedSpecProfiles() with only the
        -- selected specs. Writing here would bypass that selection.
        -- Disable all reskin module syncs so the pre-logout sync
        -- doesn't overwrite other profiles with the imported data.
        if EllesmereUI._reskinModules and EllesmereUIDB then
            if not EllesmereUIDB.syncedModules then EllesmereUIDB.syncedModules = {} end
            for folder in pairs(EllesmereUI._reskinModules) do
                EllesmereUIDB.syncedModules[folder] = false
            end
        end

        if specLocked then
            return true, nil, "spec_locked"
        end
        -- Make it the active profile and re-point db references
        db.activeProfile = profileName
        RepointAllDBs(profileName)
        -- Apply imported data into the live db.profile tables
        EllesmereUI.ApplyProfileData(payload.data)
        FixupImportedClassColors()
        -- Don't ReloadUI() here: the caller (options panel import flow)
        -- may need to show the CDM spec picker popup before reloading.
        -- The caller handles the reload/refresh after the popup completes.
        return true, nil
    --[[ ADDON-SPECIFIC EXPORT DISABLED
    elseif payload.type == "partial" then
        -- Partial: deep-copy current profile, overwrite the imported addons
        local current = db.activeProfile or "Default"
        local currentData = db.profiles[current]
        local merged = currentData and DeepCopy(currentData) or {}
        if not merged.addons then merged.addons = {} end
        if payload.data and payload.data.addons then
            for folder, snap in pairs(payload.data.addons) do
                local copy = DeepCopy(snap)
                -- Strip spell assignment data from CDM profile (lives in dedicated store)
                if folder == "EllesmereUICooldownManager" and type(copy) == "table" then
                    copy.specProfiles = nil
                    copy.barGlows = nil
                end
                merged.addons[folder] = copy
            end
        end
        if payload.data.fonts then
            merged.fonts = DeepCopy(payload.data.fonts)
        end
        if payload.data.customColors then
            merged.customColors = DeepCopy(payload.data.customColors)
        end
        -- Store as new profile
        merged.spellAssignments = nil
        db.profiles[profileName] = merged
        local found = false
        for _, n in ipairs(db.profileOrder) do
            if n == profileName then found = true; break end
        end
        if not found then
            table.insert(db.profileOrder, 1, profileName)
        end
        -- Write spell assignments to dedicated store
        if payload.data and payload.data.spellAssignments then
            if not EllesmereUIDB.spellAssignments then
                EllesmereUIDB.spellAssignments = { specProfiles = {} }
            end
            local sa = EllesmereUIDB.spellAssignments
            local imported = payload.data.spellAssignments
            if imported.specProfiles then
                for key, data in pairs(imported.specProfiles) do
                    sa.specProfiles[key] = DeepCopy(data)
                end
            end
            if imported.barGlows and next(imported.barGlows) then
                -- barGlows is now per-spec in specProfiles, not global. Skip import.
            end
        end
        -- Backward compat: extract specProfiles from CDM addon data (pre-migration format)
        if payload.data and payload.data.addons and payload.data.addons["EllesmereUICooldownManager"] then
            local cdm = payload.data.addons["EllesmereUICooldownManager"]
            if cdm.specProfiles then
                if not EllesmereUIDB.spellAssignments then
                    EllesmereUIDB.spellAssignments = { specProfiles = {} }
                end
                for key, data in pairs(cdm.specProfiles) do
                    if not EllesmereUIDB.spellAssignments.specProfiles[key] then
                        EllesmereUIDB.spellAssignments.specProfiles[key] = DeepCopy(data)
                    end
                end
            end
            if cdm.barGlows then
                if not EllesmereUIDB.spellAssignments then
                    EllesmereUIDB.spellAssignments = { specProfiles = {} }
                end
                if not next(EllesmereUIDB.spellAssignments.barGlows or {}) then
                    -- barGlows is now per-spec in specProfiles, not global. Skip import.
                end
            end
        end
        if specLocked then
            return true, nil, "spec_locked"
        end
        db.activeProfile = profileName
        RepointAllDBs(profileName)
        EllesmereUI.ApplyProfileData(merged)
        FixupImportedClassColors()
        -- Reload UI so every addon rebuilds from scratch with correct data
        ReloadUI()
        return true, nil
    --]] -- END ADDON-SPECIFIC EXPORT DISABLED
    end

    return false, "Unknown profile type"
end

-------------------------------------------------------------------------------
--  Profile management
-------------------------------------------------------------------------------
function EllesmereUI.SaveCurrentAsProfile(name)
    local db = GetProfilesDB()
    local current = db.activeProfile or "Default"
    local src = db.profiles[current]
    -- Deep-copy the current profile into the new name
    local copy = src and DeepCopy(src) or {}
    -- Ensure fonts/colors/unlock layout are current
    copy.fonts = DeepCopy(EllesmereUI.GetFontsDB())
    copy.customColors = DeepCopy(EllesmereUI.GetCustomColorsDB())
    copy.unlockLayout = {
        anchors       = DeepCopy(EllesmereUIDB.unlockAnchors     or {}),
        widthMatch    = DeepCopy(EllesmereUIDB.unlockWidthMatch  or {}),
        heightMatch   = DeepCopy(EllesmereUIDB.unlockHeightMatch or {}),
        phantomBounds = DeepCopy(EllesmereUIDB.phantomBounds     or {}),
    }
    db.profiles[name] = copy
    local found = false
    for _, n in ipairs(db.profileOrder) do
        if n == name then found = true; break end
    end
    if not found then
        table.insert(db.profileOrder, 1, name)
    end
    -- Switch to the new profile using the standard path so the outgoing
    -- profile's state is properly saved before repointing.
    EllesmereUI.SwitchProfile(name)
end

function EllesmereUI.DeleteProfile(name)
    local db = GetProfilesDB()
    db.profiles[name] = nil
    for i, n in ipairs(db.profileOrder) do
        if n == name then table.remove(db.profileOrder, i); break end
    end
    -- Clean up spec assignments
    for specID, pName in pairs(db.specProfiles) do
        if pName == name then db.specProfiles[specID] = nil end
    end
    -- Clean up keybind
    EllesmereUI.OnProfileDeleted(name)
    -- If deleted profile was active, fall back to Default
    if db.activeProfile == name then
        db.activeProfile = "Default"
        RepointAllDBs("Default")
    end
end

function EllesmereUI.RenameProfile(oldName, newName)
    local db = GetProfilesDB()
    if not db.profiles[oldName] then return end
    db.profiles[newName] = db.profiles[oldName]
    db.profiles[oldName] = nil
    for i, n in ipairs(db.profileOrder) do
        if n == oldName then db.profileOrder[i] = newName; break end
    end
    for specID, pName in pairs(db.specProfiles) do
        if pName == oldName then db.specProfiles[specID] = newName end
    end
    if db.activeProfile == oldName then
        db.activeProfile = newName
        RepointAllDBs(newName)
    end
    -- Update keybind reference
    EllesmereUI.OnProfileRenamed(oldName, newName)
end

function EllesmereUI.SwitchProfile(name)
    local db = GetProfilesDB()
    if not db.profiles[name] then return end
    -- Save current fonts/colors into the outgoing profile before switching
    local outgoing = db.profiles[db.activeProfile or "Default"]
    if outgoing then
        outgoing.fonts = DeepCopy(EllesmereUI.GetFontsDB())
        outgoing.customColors = DeepCopy(EllesmereUI.GetCustomColorsDB())
        -- Save unlock layout into outgoing profile
        outgoing.unlockLayout = {
            anchors       = DeepCopy(EllesmereUIDB.unlockAnchors     or {}),
            widthMatch    = DeepCopy(EllesmereUIDB.unlockWidthMatch  or {}),
            heightMatch   = DeepCopy(EllesmereUIDB.unlockHeightMatch or {}),
            phantomBounds = DeepCopy(EllesmereUIDB.phantomBounds     or {}),
        }
    end
    db.activeProfile = name
    RepointAllDBs(name)
end

function EllesmereUI.GetActiveProfileName()
    local db = GetProfilesDB()
    return db.activeProfile or "Default"
end

function EllesmereUI.GetProfileList()
    local db = GetProfilesDB()
    return db.profileOrder, db.profiles
end

function EllesmereUI.AssignProfileToSpec(profileName, specID)
    local db = GetProfilesDB()
    db.specProfiles[specID] = profileName
end

function EllesmereUI.UnassignSpec(specID)
    local db = GetProfilesDB()
    db.specProfiles[specID] = nil
end

function EllesmereUI.GetSpecProfile(specID)
    local db = GetProfilesDB()
    return db.specProfiles[specID]
end

-------------------------------------------------------------------------------
--  AutoSaveActiveProfile: no-op in single-storage mode.
--  Addons write directly to EllesmereUIDB.profiles[active].addons[folder],
--  so there is nothing to snapshot. Kept as a stub so existing call sites
--  (keybind buttons, options panel hooks) do not error.
-------------------------------------------------------------------------------
function EllesmereUI.AutoSaveActiveProfile()
    -- Intentionally empty: single-storage means data is always in sync.
end

-------------------------------------------------------------------------------
--  Spec auto-switch handler
--
--  Single authoritative runtime handler for spec-based profile switching.
--  Uses ResolveSpecProfile() for all resolution. Defers the entire switch
--  during combat via pendingSpecSwitch / PLAYER_REGEN_ENABLED.
-------------------------------------------------------------------------------
do
    local specFrame = CreateFrame("Frame")
    local lastKnownSpecID = nil
    local lastKnownCharKey = nil
    local pendingSpecSwitch = false   -- true when a switch was deferred by combat
    local specRetryTimer = nil        -- retry handle for new characters

    specFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    specFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    specFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    specFrame:SetScript("OnEvent", function(_, event, unit)
        ---------------------------------------------------------------
        --  PLAYER_REGEN_ENABLED: handle deferred spec switch
        ---------------------------------------------------------------
        if event == "PLAYER_REGEN_ENABLED" then
            if pendingSpecSwitch then
                pendingSpecSwitch = false
                -- Re-resolve after combat ends (spec may have changed again)
                local targetProfile = ResolveSpecProfile()
                if targetProfile then
                    local current = EllesmereUIDB and EllesmereUIDB.activeProfile or "Default"
                    if current ~= targetProfile then
                        local fontWillChange = EllesmereUI.ProfileChangesFont(
                            EllesmereUIDB.profiles[targetProfile])
                        -- _specProfileSwitching disabled (see doSwitch comment)
                        EllesmereUI.SwitchProfile(targetProfile)
                        EllesmereUI.RefreshAllAddons()
                        if fontWillChange then
                            EllesmereUI:ShowConfirmPopup({
                                title       = "Reload Required",
                                message     = "Font changed. A UI reload is needed to apply the new font.",
                                confirmText = "Reload Now",
                                cancelText  = "Later",
                                onConfirm   = function() ReloadUI() end,
                            })
                        end
                    end
                end
            end
            return
        end

        ---------------------------------------------------------------
        --  Filter: only handle "player" for PLAYER_SPECIALIZATION_CHANGED
        ---------------------------------------------------------------
        if event == "PLAYER_SPECIALIZATION_CHANGED" and unit ~= "player" then
            return
        end

        ---------------------------------------------------------------
        --  Resolve the current spec via live API
        ---------------------------------------------------------------
        local specIdx = GetSpecialization and GetSpecialization() or 0
        local specID = specIdx and specIdx > 0
            and GetSpecializationInfo(specIdx) or nil

        if not specID then
            -- Spec info not available yet (common on brand new characters).
            -- Start a short polling retry so we can assign the correct
            -- profile once the server sends spec data.
            if not specRetryTimer and (lastKnownSpecID == nil) then
                local attempts = 0
                specRetryTimer = C_Timer.NewTicker(1, function(ticker)
                    attempts = attempts + 1
                    local idx = GetSpecialization and GetSpecialization() or 0
                    local sid = idx and idx > 0
                        and GetSpecializationInfo(idx) or nil
                    if sid then
                        ticker:Cancel()
                        specRetryTimer = nil
                        -- Record the spec so future events use the fast path
                        lastKnownSpecID = sid
                        local ck = UnitName("player") .. " - " .. GetRealmName()
                        lastKnownCharKey = ck
                        if not EllesmereUIDB then EllesmereUIDB = {} end
                        if not EllesmereUIDB.lastSpecByChar then
                            EllesmereUIDB.lastSpecByChar = {}
                        end
                        EllesmereUIDB.lastSpecByChar[ck] = sid
                        EllesmereUI._profileSaveLocked = false
                        -- Resolve via the unified function
                        local target = ResolveSpecProfile()
                        if target then
                            local cur = (EllesmereUIDB and EllesmereUIDB.activeProfile) or "Default"
                            if cur ~= target then
                                local fontChange = EllesmereUI.ProfileChangesFont(
                                    EllesmereUIDB.profiles[target])
                                -- _specProfileSwitching disabled (see doSwitch comment)
                                EllesmereUI.SwitchProfile(target)
                                EllesmereUI.RefreshAllAddons()
                                if fontChange then
                                    EllesmereUI:ShowConfirmPopup({
                                        title       = "Reload Required",
                                        message     = "Font changed. A UI reload is needed to apply the new font.",
                                        confirmText = "Reload Now",
                                        cancelText  = "Later",
                                        onConfirm   = function() ReloadUI() end,
                                    })
                                end
                            end
                        end
                    elseif attempts >= 10 then
                        ticker:Cancel()
                        specRetryTimer = nil
                    end
                end)
            end
            return
        end

        -- Spec resolved -- cancel any pending retry
        if specRetryTimer then
            specRetryTimer:Cancel()
            specRetryTimer = nil
        end

        local charKey = UnitName("player") .. " - " .. GetRealmName()
        local isFirstLogin = (lastKnownSpecID == nil)
        -- charChanged is true when the active character is different from the
        -- last session (alt-swap). On a plain /reload the charKey stays the same.
        local charChanged = (lastKnownCharKey ~= nil) and (lastKnownCharKey ~= charKey)

        -- On PLAYER_ENTERING_WORLD (reload/zone-in), skip if same character
        -- and same spec -- a plain /reload should not override the user's
        -- active profile selection.
        if event == "PLAYER_ENTERING_WORLD" then
            if not isFirstLogin and not charChanged and specID == lastKnownSpecID then
                return -- same char, same spec, nothing to do
            end
        end
        lastKnownSpecID = specID
        lastKnownCharKey = charKey

        -- Persist the current spec so PreSeedSpecProfile can guarantee the
        -- correct profile is loaded on next login via ResolveSpecProfile().
        if not EllesmereUIDB then EllesmereUIDB = {} end
        if not EllesmereUIDB.lastSpecByChar then EllesmereUIDB.lastSpecByChar = {} end
        EllesmereUIDB.lastSpecByChar[charKey] = specID

        -- Spec resolved successfully -- unlock auto-save if it was locked
        -- during PreSeedSpecProfile when spec was unavailable.
        EllesmereUI._profileSaveLocked = false

        ---------------------------------------------------------------
        --  Defer entire switch during combat
        ---------------------------------------------------------------
        if InCombatLockdown() then
            pendingSpecSwitch = true
            return
        end

        ---------------------------------------------------------------
        --  Resolve target profile via the unified function
        ---------------------------------------------------------------
        local db = GetProfilesDB()
        local targetProfile = ResolveSpecProfile()
        if targetProfile then
            local current = db.activeProfile or "Default"
            if current ~= targetProfile then
                local function doSwitch()
                    -- _specProfileSwitching disabled: was causing width/height
                    -- matches to never re-apply because SPELLS_CHANGED fires
                    -- before PLAYER_SPECIALIZATION_CHANGED (CDM completes
                    -- before the flag is set, flag stuck true forever).
                    -- EllesmereUI._specProfileSwitching = true
                    local fontWillChange = EllesmereUI.ProfileChangesFont(db.profiles[targetProfile])
                    EllesmereUI.SwitchProfile(targetProfile)
                    EllesmereUI.RefreshAllAddons()
                    if not isFirstLogin and fontWillChange then
                        EllesmereUI:ShowConfirmPopup({
                            title       = "Reload Required",
                            message     = "Font changed. A UI reload is needed to apply the new font.",
                            confirmText = "Reload Now",
                            cancelText  = "Later",
                            onConfirm   = function() ReloadUI() end,
                        })
                    end
                end
                if isFirstLogin then
                    -- Defer two frames: one frame lets child addon OnEnable
                    -- callbacks run, a second frame lets any deferred
                    -- registrations inside OnEnable (e.g. SetupOptionsPanel)
                    -- complete before SwitchProfile tries to rebuild frames.
                    C_Timer.After(0, function()
                        C_Timer.After(0, doSwitch)
                    end)
                else
                    doSwitch()
                end
            elseif isFirstLogin or charChanged then
                -- activeProfile already matches the target. If the pre-seed
                -- already injected the correct data into each child SV, the
                -- addons built with the right values and no further action is
                -- needed. Only call SwitchProfile if the pre-seed did not run
                -- (e.g. first session after update, no lastSpecByChar entry).
                if not EllesmereUI._preSeedComplete then
                    C_Timer.After(0, function()
                        C_Timer.After(0, function()
                            EllesmereUI.SwitchProfile(targetProfile)
                        end)
                    end)
                end
            end
        elseif charChanged then
            -- No spec assignment for this character and character changed
            -- (alt swap). If the current activeProfile is spec-assigned
            -- (left over from the previous character), switch to the last
            -- non-spec profile so this character doesn't inherit another
            -- character's spec layout. Skip on plain /reload (same char)
            -- to respect the user's intentional profile choice.
            local current = db.activeProfile or "Default"
            local currentIsSpecAssigned = false
            if db.specProfiles then
                for _, pName in pairs(db.specProfiles) do
                    if pName == current then currentIsSpecAssigned = true; break end
                end
            end
            if currentIsSpecAssigned then
                -- Find the best fallback: lastNonSpecProfile, or any profile
                -- that isn't spec-assigned, or Default as last resort.
                local fallback = db.lastNonSpecProfile
                if not fallback or not db.profiles[fallback] then
                    -- Walk profileOrder to find first non-spec-assigned profile
                    local specAssignedSet = {}
                    if db.specProfiles then
                        for _, pName in pairs(db.specProfiles) do
                            specAssignedSet[pName] = true
                        end
                    end
                    for _, pName in ipairs(db.profileOrder or {}) do
                        if not specAssignedSet[pName] and db.profiles[pName] then
                            fallback = pName
                            break
                        end
                    end
                end
                fallback = fallback or "Default"
                if fallback ~= current and db.profiles[fallback] then
                    C_Timer.After(0, function()
                        C_Timer.After(0, function()
                            EllesmereUI.SwitchProfile(fallback)
                        end)
                    end)
                end
            end
        end
    end)
end

-------------------------------------------------------------------------------
--  Popular Presets & Weekly Spotlight
--  Hardcoded profile strings that ship with the addon.
--  To add a new preset: add an entry to POPULAR_PRESETS with name + string.
--  To update the weekly spotlight: change WEEKLY_SPOTLIGHT.
-------------------------------------------------------------------------------
EllesmereUI.POPULAR_PRESETS = {
    { name = "EllesmereUI (2k)", description = "The default EllesmereUI look", exportString = "!EUI_S33EtTTv6d)vPFbGX6QLu)liK0WBtcSaPB7o7mmcBbOFyl5vwouAN97(7ZLZvPJSTasA3DBMz3cg5JoNNZZ9R)(pUomBzrBo8djzfBkVCw(IIQjhgh(9)46PzRN1uuu9(kVWWjgFWFVYpkEY3)VXVD7tRkG)ZTBwSa)gFPOzDzDvva84HzZZPL2ZpBt1I6zp8H8NQ30cFY0S8Qz3x3Sg)RbzT5n3v0(M81T3K3aFuS4tu)a(nQV921fT)cS7scm)h9MwxoVaE6Jp7QRo7J6N(NROTPFy2Bo5JxpBZ626Lx7n5A)O0KjHHxN6z(2GDc9y11lMx)y1AZ36b0Rn0pmjjEs80PE6xBq2vNDU578GPrhg6fhNmDIN3uVuCl45LDBnUbOJQ5BnI)dMVmVdJn(30T8Qcdo0cwGVjFb0R)Rscx7boJ8IddssM4pjzlVS4yCFnneaDWzlIowDazwGZPzV9IJV(nlYxV(II11BAMv0hKAS93YRMUgbyiE)SPTCrz7tJ7MZ3ZZpoapGmQjHW07MtCXffhMg6f6HV0GSv23xXzRwK)urt)JIFO30KjaQvA82rkpGHKIxZKy6W5Z4boOcCGHGKJ7cRpn7YwGmR44U0u93)b0(rUHmWTJYU40F49xzHD7hWiDE(Pjj(j4MpLUPpV(XclYxVDGb8IjLtak5yV0GORtNyrk76ski9qGOutvQGGHzF4TVZ6m27iIxqtYESCE79FmVD29aYNXzET7dAxIJHEm7B(1QRBaFNiGa(IWDOZVntvCFr5D33YBmMOC195vaVUJR3unF9V)VHpmolF(86kKJRpSUlwuSEzrtXNp9OzTahB8fGmJNMnVCD(nlkExDZYZZVRS6U3rF8QnRVVy(BiwOVPErnEr7bSXrKfVSBqHgtqPgEz3rSOtPFUb(50PbecEu267RF84fL)2VD6m4nslCQyH)86cIrbT0WFW3xUrU8HNAkNd7d1Ub2)3dKViCb(4JQkxMJhH1WviE0BQN9dlQFuVjLBIUBo5MgLq4dl5D3VaHJ92ktYaEf5TBAYBloR6ncXd4MmktkS4TZVRO7x0dWcjO2X1nZlAUS83kQiquC2nAOWrlWllcm6NbY)oVEDjDCiPZW9sabPFQ6aVOPhgbpxswtXIZRlRAHB1382pD1BV4hbSMvIprke0l7xR8eu2t9Mg5Ns3d0Ag)swZjHKakwqGu62FBtXMcGHt7gcpc3VGu2dtttNgfLeLgGsw2XoxEwWD(b((Si3GOj43xT19FbB9dCapa6NFQ4(YzlkE7VwIsMzyDmZTG)hkcEe7DVPwC2uB9e5Qh6LqSq5dhkTye3Ph4j2APjHaOLKsrxQrYLpAkT8kq3OwEsuBC2ffRybhi4iAcVFf)B37xZBsAbJY(5Z1RxyQPkoJe6Y6c4N92Qza7T2IgJ117LUUeGCQeqYYPJLupJcoEGFQPahFCxpn7J5LiVwfjIFePo7ZcrGbeGm2FTTjxWgFtBBDLA7p9WqGamauijmjez9mcKy)esmFSxcOCiRJITgfmDY0qIozVbrw04bPmELHQeXzNxGI7uKktjO40a)PGcQOuLrCgoi(qVjbrErX(rfhmHuzLUHdvKkbJMNka2r4EQwIrx(7AHqSbveZ9PwYkEEIqtZ2SUGKGM3m)eW6kuSnkgn2AXjjn(hsVwVS1)Rn5nfOixsczC2YAyvQbt1UeKhF0If4c4RKBEfyrhy2e9KgVTlBFcukGxWIffZAbXAWl3aLWqnHRk(vqCzbTu(0vwj86)h11lRIiryGiCPCAhIBvIIFbQBeIYsTLH6dajGHXzcdjpa3zGcd3q0mNdQhbAtqBxVWSVuU(9GogFQ(TvflFIp3Sbv)DujqcaLMDZDVTcvwAo8atZQ2S8I6hxZx3Xzieg0CP4tBwsaF5stBI3vx1QXbUrOg1DI)Bd8FrCm1(49WvgRk20Sc(vYA7Gkc9X8zn1iih)OWShkE6MYQ58XeTaM281nLfvG4zuZcqvwW47YFd2d5Gz7aQSungCv(f(BYFXiPAyxbQ90wUIW28ZYx8y(tieAErf(wtYad7p72lYRURGowk9gnx5DFGJjDezn9oQPbGM47dUJYB(PY1L3qw(bctQkaGlT9UH0T6kqa(dvfRxJUK4(YklscewtKeE0LRp9oGT6d41cReQ5U8Nnp)GQA0lWs5uIwE5n5TibKgdaGc3Z3tiQJXNhzIlOrrGJfT2INeHJrYBp9EwW8GH44l8ycFvayuit0be1XsJ08rs8iIBI2iaBPFKXmWpimBjI1SFOHrAYHRiAaHjbgxtxGAoZ3vQf2cMBq69Zew(uG6XKl4eIXazkH0mcPjeeTWeb0IxvMeB995RkyUVozO6CHcYUdqSoPSbyIHud(zBwrGiMrWL4AcOrv1vfeMTXlX4McyMSaW5U6(M6n3DpEYHBzBAasgdAKbBJeAxe)tObjKDZjipdM5aJBAWC2a)XNHPsgxe8X6Zeu5DO9)fjjSXjGGEOcxkC4o4QsWaZMZNvaYqnyL7LEpz0PusbWV8SQfpDA1AYNdc2emev8KowlaluklsBgey1eHyrMYA8exUQOyocdj8eyFoY79ytARDWkYYoPbzk9vrWHwpbKz8UzzgYs12pkz7B3qcs2NWA8W29rQtc6D42sqJitMuAjBoL1yjUBiPmBrkWaCQ7krjwirBy(aJb7zSczKES1KKQp)LVPsxyTlSLUWSOu6KyiEXTuYVXYygwlMXkQXjBPxzXn26qHYpgssZZqUsp599e0yPlSq8X3sXmoup2ty0HuxSoQTfJkHSlzmmhT(QfVFYugs6RLzdYqr0XHx9VpDVAdWqs(XDKg7gtCiobdkSClS76WNrk4JCvLdZp(QzV03AXEwcw(6iWRRzwU1J4fAH1lx2N2AQbub(RPOphwW(Fus(gMU9BP5vVEI((ABL1Zry2qcg7zuRt1q(Jt0Nl16(Qk37fyo1(l6ZWt(FvK5fXHzTkCcPpGBjG7Tanqp2yr8rR86Bm7wmVSJdZE)zxC6)4SpD1rFGuvZHJEChvIximAir97wFbBZL7Zu1bGLc8J297djVAqxU9k420VQQbmiXxFUEVsEw1LguUe4VxM5oGQJdi1EVjr44hi8A8(5gHr5cvNEy3L5pFdDE64mV9)2eY)TW(2)xxqVTN2cEfSTLxJrBQYRTPVu8tPKW4)snpSVFQ)lBf7h5T)YwXbIb3WEj9)2eJ8x2ks5J(Rs042tBffbj8L4I0x3WWT)2nQtrTo5HbbaFbPHbM2KMXzmGtPkJKvZi3B2RyQT7u5qsKpIqVfMD968VqznJrkFULuVy0s6Fw5(X(7uY9YgLxU7it1Xe(pMOXnaB6xSBj7P1TibBmS8IZTHHY4JXz0YFkIjxF2duE2)NRm)4)vcfNJ8nQJvk95C6wUKJiXzNmCp7qW5YMcDYnAgsWUPt7RS1iDLQeY5SKvo(9AXH(z5rioxohLBB2MZe5AEBVepcIt7LnACQhkYAsJmdWzQJ5ohXCNxw9CF)wKyovK5qCMdQsjTrLhcJkhQgThshNl8gvQ90x(uF(AUOMFooQzu()ZronsQX2l8nUZ3e3YX6vmric4asU7K0tpNKp0bRZNz2hoqUG23wQHJ612sL3(5SncyCPX9(NQHU5)6mpl6LQUgjwLRuoXHh5PchZv2n6mbq6Lz52YH2xNF5UESChIeDbe8xgYORDT)YqMUbC5VmK5VmKHtL9gUne8vpf2)ldzQ40w3HlG(tTHm6Qo8vwKIH0qYW7DvIsu6tos1o7wlqUG0Vwwkzxhtwzu(akw9SSTIlYjlVkgjIGxxtFzNYmu9j52aHbvOAu6vpKIXdMEgVwM)9YQBPX5fRNJ1jJYEVxETn96L8DFlIl)GLUM7YCAGW81ZyZ)4YYU9YOpM61rvWj8yHrvO4iZF6zC2(AwXO8oJddY2s9D)Fy5vws2hlN1ulkS7x4MF3j)Mrew(6MS8Dkj(9r8nPv8(LQCDfc5B1zOOY4ZHf0yhoQJO(VQPvN7iB5Go6RJwaVWQzEVcR1OD032ngCaMWJ0DUJsBHDWMSxvVoQKX7VcTLOI8)ZxOT6wLYdxpZM6X)AvpZFZkZSDgBlhSoFUMeAPgbLG57tblpQiBfNDC(D)xNWsZUk0xfva(p3Aha7bzt0DuMUnqfViv)sr2xa4UwMrJC7Jp1EF5SRkxsnHpQCvRF88fBwF1J10NYfzA9n)FyJp4lfDJ13Kd5E2g2Ncm6EBKNRGfB1IY2lxGT4pZAsFYHCjxsFlXpk6EjPOvXIsAw0ykWD0zY3VOB0ql87Yx32BHfRRUNjekA4rfupzPUzwX6ZN1EE961rzF4OJFlwAgbz0FfODS3M0oG2Lr8ggBcdbCtSKfKsD6f47X9ZeRTkc(WTBNebLaWnfFPS4rUJy0IGzbi3vL7JT9b17wayNxK3Ep(coT6QYwUh7iwP3(RRkBkMBFqOyNrhe(NOUBNOxCsR1AJfcPYkVR6OflWBBamjANJG(Nk8G1g9Pd(Ctylh3uK)agty2ziQh)hYxXDXUjz32KVSq2OiqlS89yOpF3GVsSncM3s9j0Z(8NU66ZF7fyhGI0aUfpUFEDXrZMvurnVg(1taW7BkkmWAji7PyRZ6df32kA2nrzRn7Vsk0naULxnVyELVi3YWMsX88f1vfaYc1)zX3yrZVapX0d9NmzINp8ttynN5)2pxLKqTXn)iV0OapQbELMLF7TL)QbeBcTL5Ja2sarIyS5VOGcFi)MIf4HZJFs87Z9hJqtGfIfNM95pDYBV46Jp6ccjqIjBbJcZymMonhcazg39mMH4hjudQP)5hsV8pVAw9YYQ7UeP54w5cTtaaPccXMojbCs6cbehoEkeH3uVCvEtXhRNJTlLpD2NElcFAlN9G26lFooT4JUOOTy(hlxSOCDXS6Q5e5p(8ssg8gVdRf3CaWVeG5WxcyZZdElD3vNuSOnhRwC84X3rNqeh8B9MI1Tkgre0G6AHrzrrPzaKp9aVjh4fo93RIIOl(Gm)G0FVkik97RsNg(9Wl2pb()tsJG))a4tOhc(6QVsCMxSxMxc8TsI)(QPHbWtozc8D9N4nf(5qUXygJln)CBD1HDhVGg7UTVYbzHt8)9ka32hE)aFVkF4vcBApp8aaFa965ZSX(g(w0(z7FXaC7SRdhSP5tN5MExht(9B8n21jGEf41tcC94njgVFMIzStfE7egjBaP8Zzb)g8lqGMM6hr(DisMqkbZBKLseK1ciTaU1I5Aoc(b2iJeEVnETMqTR4Gjm9aXOdFd4VdO67SlWKGYAfCI94EETvtE9taJ6vlYBleDC77ZxF)hkR29cJNrGtdi4VLYNgemCFr(I27)0ML3q9GlVS26v4dWTDocwnv0mJXwbMUPjXn11vflW(ZkWud7pCYg(QS3uRAAsrAj2WTQusxi3jqHvAg3wC)CvjYTUzZQ2sWim1x3LAjKgkOa)OSfGueCpB1SVagl1RAWJzV)uG89juObiG5JUa4Cv9kG5hXWgH1KGG8nn5NGDn2YAkXQ0z3jS9lxUQUby6sT9CeEW1RjHAaI)Rb(L8o8haCqGVviTLX2x4T1vGK8OStXZ9T5Zk(NhnF(zvR)Ng6c(pxwmVm)Fsp6)eehcyPRFm)PdV6kugvai5USOA(cAVICjL98TdyjMYEDNO9fYvIlwhT4fpIAY93pDxYkmRjVC(hZBEq0NB9jve8yO2DczkSALEzvWB1QlZLyJKTt0Da5UlWDNFhGHIXLL59oSAZWEpm1)Q72YbX(3Lb9k3IJL9NpqTOBV9Q8Qho6U7AQv4EjC6HtIINgR1F1lH66xOQpmfJfqaZEnqRLLLu7lMrhOxhgjQBVfBtymfg9HHzk8(lkYNJTdDUzJPF1G2TsYMusigEqH7dHG)FPEJr)ml16OyqZoj7FTbKw(X6BiqSUTK5h3hjw1h(yezGOwtFSZBixufitQ1alDdMkN9LIMf5pjXPeGO7lBVP(xje2FgfZIFbMOL4yZ0EKoQtmUTF7YvTp5UxC6spBckMKbQqvEdOVMcMNMOB91(GCEjypYJVWNs3G0gr1ENve5WFpHqNVSnF2d7xgyk6r4iVdjdj(idVP6226LoyGPPqrDnbQbbVocqrCUoTcuu7MCUjitnUUaInh366e)SQ51X9Rlb3CQ9GYD4YP2hgJCAxH33PflAY11af3C93jYd1x6QE495RTPfJ13JjAdM4wbliED2mB6ka7WsExNMHPbFzJnA)K3JfpHCx1iEajR(UXqwjJLsBdT1mGOibLZBiRr295ps9kT6tGyH1aOE7vRKBIXfkBwWm2FcUqAbiLukY5OMfwqk(mHN)DVXbdUuCFTqmIYEa7WIW)ZGpLupbkhF1amyry9b00KkmxjpBGzSPdeWDNTyzhfxlsfmH6)3mvG8NrQa8NzQB9b4yREAPU54prG8rRHjIi8ZSdwKaZEEUiKgkhI(QVI1sGh7nKicT)d1yBh1gZ3t7oNPAmFUFHJulc8l0EALGCqpsaBbzEOu4anoeSO9iGbL82rufAMRGgnxWAsDpmebiTpajs245dlxwnDae(nIG5LZusFfiSkujdIjaBu9XiVpmZjqMKe4tQk85fnOn8vCzwd0FgCtm6fNaBBt9HTiVj77xS4KceikAbMMY0zhWXTryHuSDsEeti2Sl9iEYPXAhUfP1TWpGVybBwCPa70SQInTn5l0823g6rGI0BNBqauHN73j0Oe4f8urdDhbA7VA9NkYB2F8su4SsdfDp3L9nKHUeDyllz2y1ZJzxEqlcPzNa6BOHVq16igKrapLcdwlf7GquAlYM2E3W8NnWdmX2qJhfulOsVKjyw7DnFEKo0e7hdLKPEZylZ2q)qTMwISS08p2XCtF9vT0Gtczb5LUAvXCTnxkgnAvhzjLPzZjS6H1HHDYc3mEbiKttCiLe48V)(61TLg2RrT2DHMgAS6aPNnT0bvBK3unTqIHFD9IyoZbAIbT4AFWekbYk2oLpP428nlizvcVYPmZHnOMmOvZNWIxGgz1sORMBU0alU8eu4am1)QFQYJBjWjmhk2yyXMtGMzYTWsNx2b)YN(tN)gA7BBfbR(mDPRT5TJvhAEJY)Gidf4BCT(rcaHbbQAoWmudm3uDuRxlBa3LRYNPA66KgPsRETE4EKLQQU2qR)FrQ1FmT0OKDN6Adcm12Kyq2QzSJuI7MTxGoObNlCJAk71dbRDPrYO7hBBkb6Sd(IpCraAbBPAN2kAHxt2xrda7kdIYDVJt7y9NnxcpqbF)OW0jEPXgAC44Jj3kh65nnoC6KOKeWGu2Lm98Prh35oX3lomki0pnKgdxcDAs8Ng57feKm1x8X0Bin1logmzoYlv42Mqn75DFArfJqbTKX0iJh0ZdfY5E0MsMOw6rJoU1beC11sIESgzfy0(s59oxlwXu2K7oTKFudJpv3r4OwvtFPsBSGD0wfT6QIwXRET1yY81SLRBa2lWhjWRmyGX4WOCnIVoZXHvS62YzKJRiDbnTvDAwtEtXBxu2sZucMVkpEanlRxY8rTTxIFeVy5iPaxg53SUU5g(Ubu8umwlm0rQJdhq3jrGGDE5d4Isw8QBfMzUhLjGDTYRJ9OknO6WfIIngDtQNnbSZz6CXGtmkLI0biFncBBnAGpWVZYCggk8Mff5vm7DwbuFLlknm0CQdpUGIXNnJUM0kYy7jZU(AtZM16Ghi21YhxynVLxPusWv(2RdxeTuCLPkmHcyyTPOSEUqCkdEeIeSqFTvsY800Z(b9FeXXsmJpolPKd)hJDqoWXDFf2v(5zOqPCAQamzaLy(bz4YURPEZQ16Rxu8hQp0rKspP0uqHX3XK9e(dv2XugJS1IcPuE2)DCe0UO4oGyu(ALRR4fpbl8wzl6XQI7YP4ssxrOk5baj6fOfOIvwR0bP(dR0(gvezZVruT(6a6zfY1E(9qUVG3bS1X32X0Bt0N5TuqKbDWFhpKCSrb(JlafwWTHR0YM)g8AdSdrLPOtg(oIiRIaUX5BARXOXUQLVVpT6laNks1iJVca4oKTcNzb(5k6QJNQkUYuhh12mE8W1HaMYtU48y8Qq4DsmjUlaHT2tseqx0CXa4RQcSB6D4Sfcogg(Yxo7mfJOptpDKMb8QbE3ZEqFGyBv(G4ZzRIVRjFoo(xSMFf3nBonFaZBE6c5e5WaBflAuLoPIjCJ1ONbD9hLwbAp8LQEt4(jEQ3KGjXXbtc5zdOUtCAnoXqyJ(KCek7hbP6fJjFKdnwUBLhLDB5If4vFGsRLPjSVx9ZmoBkitQyk0YPaGy6vzpO2g1WLsmxZWTbDh7ffNe7pnmAskQWDhAuR9K6mkWHyeAm05yiuwlVo4HK7VuDqec9eeVAK2lLxamvkD3X4FAqhdGctNgKe45fonLb2QS8qgKrXB(ybJk8VdCIBEGdZj)4INHY4nkmLk1Wna38gWMrG4XfTzE2UL3as6QkwGRkX3X44)d84DXb3fuXzZ4oHGeewsknXmk)H3CIeRwe6FjuIF9AqJ4sljiy6uqvZGyY(gJ9HCL14M8fJiPf0O9Y0oZ3JhgA6Hgi6pdKfvX83UCf6eIlBZVtYnsraXWrb7sfUnJ1dSgLuVNu2G7pZorlNWmI5yKEFYxcmjcI)hMMmji1xGHIIJNMDxbWVH9huVPdLvZUfUh0r8ljlVTPEwz7tDjiLKNa6kg(f6DSQPCjWEzOMf4ajbF3zqvqgp5MjM9corMYvLZgA1SUIsIi2DEaQvAgWI7HRUVyjMBvc3iPchKvkDXo)xKZsQrae8PYW8ZiaisI8t4Bjj3iHX8fuciD6TFQwY8MXfvFlKSef)yZKqXF0M9iNvsY5FnZmGc4VwSSsWU5GJMDBTdjxDew5SeO2xz79EHkAsMhop5VzEU6zuQCka6yw(X26OGui6ljOEiLC2kYRsgDVT5W0SyulL3UwdHj1NE(mPBIDQ8iJmyIyi0zHD2TLlUnoPNN30wMVqK0sAIxzA6W2QYQS6Ad(vHAAyIhwKSqJab69lJ4b4JtIV3F6eVEnSid6eAi2)TLoPVOpLoWBNoXjgVV(AwJX5q50TGk)mjoCBuKt86dPHDUitySmNCac2Ui2GYiu(akKt8sWTJrMIhtAeyQtUu9rMdQAy3yQD7wftyHPl0vzFfiaAb3JniR6PyCK)SgWWK4vrU6YZ9XEweAjQjb0k1huo2Bc8AnuZ5NYxSPy96jz9iumOJOj3mlGXU010T5jBbkjzZUhn1FoQHfn2zb07vLRKE7fxfXvfBalZL24JfwrfIFRZShCLDvnrpAT7kzMmbHDNjAyaN)cm9Oy8b6AGc5uyOdIUuCVjNSDYdbI5j2goTixbzyus1VY7i1VI78P8urUUEMr20oO0c0PYsuY3GJdoo)BWzu78ck6xNERHQicOplwYwx9biYfZCVUYVsqOGmVd7Q8RMspLhzUHMM1(3Q)aillg0TRznpn53t7UDw7KU9xGr6HpSpskfZSqHG3okeIoo9nLnZ4qv5N15PXScfTtsBzTYdjuc5G6l3Mp7EYZcrz5Kh(sW)sCgAu(M1S)(MMHJmvWAA4ZRWCMFrhPRD8Da5mN7Php4Dhn9DVdGVrzTn5L448nana25(v9w9z1wfqODSx17UOmAg5V9nhTd4n37O)XbM2b5M8XM8Mt8tpPVlsioBsR(aHmiq6Ag(aRjwHjTTlkamB(W2zqD19ZuS(NlYktJ84pkt(HwrYdZzh0UA5ukgoAODMMJiuleMUlJ0OtANPTy0OTvXT7ZrxAS8kqRyqpVPyz7SEK4ArdaKrF88p85lV(OpDY1xC0Pa0piBLv5r8Zvhegp5Wj4)cs8crws6sN4aFpU(ic9dbZNtaA8E5D8NRkBFhwLi0feh)gqg9zyC)AFsYhUxELAALjWOTEDjnPw5lzkgBymlGfAmgv4XFt2l0J5lkRtWr)nrKhrwc(uLFIyS9ts85W88RvXt6oX63BJKceouF8GcZu0bufXpb5UpIXQoP(HvcBJRIaBysS304PKsgW5lWleJKxY0PP(PXym(37ZNzEAkDyNpfPPXVvxrzLIAvCUvpiamNGq1Ne5nLs)89DVceoJaLIJ(fIAi1iIeiOXwaLVQw8eNjnIKjcZOcoP6WQCceQ)3VVO60k03XFHCyoiiLsefv8XeA54dKpnOCbG7Z8cJqeHe7GEbc)KWUGcDxLEv0zKa5FwrDxjyIQ3m8Ca2J0ZJJ9iSf1E5Mha1C6RR2Ccvjt58ZG(yZ3gMsDW6itE(DgVprI7iFEJO63dSiCUOViwxQSRhJBabgLrevL5(KRf17EaixrjmhLM)ICmw(WQrUmU9Vahs5RlExjpI9LaCj3SOSBkwu)iPD8Y8FvCrlY1zp(2rOGPr9NitcjEf5WmAgxzF8cxFVY50o64mUe00jbSohki)kiEtbMkXXCPervuD3jGGCmLjFqVx55PFS1gJZpd5MJCmhaeogtCooR3fjYg)AzGoqow0CpglvrO4urwNHgM4mk001LyTNPjJeP4if2AHJLiaMEU(JspH9XrK33TI9nakuL5WryHvAMLKAuzeCZy4MEBu00t7EHjal)ciRfp2DiuuaBfcOfDsFyQoBs4SMHdsajZtP(JKJav6E(z(ZjudnLVa1W8JeFxgY0LObztcqWJneSltaFteuXY2JKuWma1feXepPCnYU262(EGnbP45UzfyvwQEXIS5SdOWQrRZV2ouRDUhyUPI0t0aMU79JjnNckkspafsihrgc7NJyhbqnkGwc1FfI637AvDBPXSeFKRj7TK9g6tFy1seaDt(1S4etUie4s0ywjNRlePWrhY8jL67krxf7ePwJMuZs)RlEvkyJIosDkuFI4z6YrszqVq4dYX1oTeIdmsbsJKHoMRmqmNwKLVKvYzWXSXkCcUtsCsDN74qtR63JsHmcojKw5yEhZvYLqDyfhuXHJf9P(uRYNOBrwrj2NrDzj1Rovw(luCtmZj99jF2z10v7a8AGtMsLMeIu2rAAlz5aPa0(QgISA22FGzxfq6Xz1TggA1Fmz2nKwb28oM0n4WWn2iye1vEVkEsozT4O5GUfTogMS1qkKstL6kutfoXaKKUC2q7uQIgupSGGTrqRkruP7XeP)rxY4jAT)u6nzlevi9Zn9(WkR2tLLDPUPdHFdsvnK4RPcoP906JdE54jcTuygHeCDBivW2i3BNCyeR(nvIkyDDl4cDOhxLiGTA1TN)FsuOC6V1jT62xYw84p41blTsQe(oik3cjORPF1WeFdrWoajOdI1bW76sSUfQIxdA2rXbCalh2nDVqGE3V)ZGm2HoSrI0jOVwcdKc0tnsShkpM4MUIhLPpI8QGRtHVcIIhGla7qdwVEuURdxgGC4f6wzZtQNfqHz8Yj8KKGzSBl8XgcQTfNDmGX2OuLoCg9kgVer8xmvCK6pnkQXbOEtS3OIu6Lxovo36sPAoQDgwzZ15ESihK7L9TMNsf4OVX2Br9zUr2Gq1JOe8vF2CPW8wTAFyDXzlxeIzdjVe4YToDnTo1gmkZ9DH9NgfZyEJkNTCPjCxl2OcC9EcB0U0RaldzNazHNPu4vdReyG4d7WdiBZSiqPvvLEbVoH)S2QphibJApdU3jcSVx28coOosTP42NiGEkmmIKuB54nLgVMFoyvfHh6Ka0Hl3UP9gYqnmHVeqVb942xv2CZO6e)0Q5yvcGPOOiNCPSrR6cWykUGNgYugBF1mSAMosEjFSu0SH(CrNPcQa77bxreeeoAcc)qnxJdAV4midbxUAdq3BVH37ouzExEAlS)W2sQKGvTlzMu)wKpDjB7AZgXmW2Lkkcugoi6bwSl13P33mOU7zT8GYAawSlkYHBNo4kV4UWaMsbDCBxQ(qz5nzqEx7nu5vkP20U6YicG9LST9PzdloqyBVsY1Ej(7qD2arUy1PB1EooBAQWXrpTQaR2NMY5f)oxiewvanhonzHP8I8O0qQ8qz(QftcUWha2sihmI1lE)nc3(GnAD7vu7ex(mCdiNzK((XhlIoxStimdrlw2LWpXbHYR0U10XOeasSruE2c(zQrlj95TeXcddkhhhLNTht8BEnAsbGCpmxo1vu9v1uSD5Q9TdzUHB0mfntqv0Tvy0SSVnv2KLk4Ab3MkHi7FOGWobl6KnKjQqVJbc2tFuuUqzWCsbnzxR)SmzIT0rLB4g2QwdNQoWbN1G6WHcYHwp40IWcTxHaO4HB4KqFeB647SIWUtDJqxV1EJA7P7jcBvx0bdnsp(88U0b5v3Y6xIXBfnieF1iEMDCL1yJ9KZydX5p3LWvoQRIHWd7ncxAsNwHPN7tSRX7PBpYlOiVI0KtiRPl9lYJxkYvfigtLrmBMwQQYKSVJnEHUwT9Q9GTOir1d2X9jdgTvsajZ1Xk6sBnSNd7m4U2xsGwA5vcGD6i7(rxtR7dHwtRHzs0qfsnLk)iOqZIufPjtam)GOroBps6JXfh9cEx)5jXGozvEGeMQGmPCjhIJXI5brC6KnlvPL7YwtbrxJQ7yWvyitihmYDd5VkZEDJv173jObk5zA9oyHKkfLa4ckmHLARLK4kqKd4nG(5m1nIaW0nqmoIbxhEI7BK58P4(B4(qrSCCN3aaMVPSiPg7KH6SgloszHT5KJTzb8u59Un)lB3(pue7S0h3MdTADTyoSRMMNYD0QMDe5aBLU4msm9RgrEhKcjzs2JbQOU21XZwJF7pDaIhl(LoJrNJCVG9Eb78gdhsiAMi2mv3vwny4gaJaqbFRoY0732b5MGYDCoYP64GdfuFznsn2WmGgUAzEgduJX7kJ0eZvQ5(mYsP9ZZjUr4SCOIWXjVqxKmOaXbI(GRudQFNVKckRd)o)c8LrFDh2MSYbDIHDBmAOmi6L5wdhjqKJ4j7W3e6K7554Cc932rS83M3j2g)g9FZuTONV7egxg5ShEsGZULxnVh8ICeaRNSuE(wcgY4n8)pxg3)TXE9ErFj4WaJ)XH4CCjj5(Bz82s4XTLYzUmjEl59Oky2IkiHDCRdtGz9FnA0AKqrxM6(QAu7Z241rBF6GwFoS9KDtbsqZUUAtnKDDBltE2PXBUSet2O16fVE32F50382Ms1rpXHtvLXzfvEZp5QtPy7kaxgq5m5sh06jNjtzh3imGrnB17cBXEIDgAJXyw7iAkopN0BC4aAoqUQ7qj9bIGexTo7wT)HTVvy88UnIYHj5dAt34CFZZ3CMEUaXvWMfZddDC62ILvBnvuho(EetcvOknAVS2ESbBrOUIIYoTQQFWFC7)HNRzrd79Xov(YEAye319hU8n2pdJgSwoCet5)eyA03GG82ZWODYg8BHnqJp0U7Njs)5j8TFtI(6WMlzX0OBAvVh2nL0TO7(FABOSQrEDF5uNPBX9AFqFvIA6ROHv7FELlcnKEu1z1dNOkGARb38)mmc7fhxYUMQfyzo6Fz2wJT(I)5ZSTXPbkBBDN4TT9yY6094GHeJWeqNHPTx6LcKQonI71WgXUgc6OM46hCTEriEq7c3QXDoYp1TvlqJOsuEwHHYT9PVIMMmwlh5UtQ7WVT9cMZvFEXr3YAlPo)xhZfhiqhoTzBiBM52UV2wo3f8KBRJ2MDFdexJTh3HoXsA755WonYBlbdSxye7yx5Z1UVTfom7wHgnZKYXX(TQ)wWfWp1EmfPNVkgACpZuLnhwTIcm6e2TycQ5USQO9kUIF6vUUyB2WQ1gJdNfS4rVOyzz18IgQtz4LnRUA9ML4MK76XInm8Z(zYU9B(M7wwu1EDZgQX7onRfBw9pW)m3SBWeqXpBbEYIYEeBzSCgPuw9WtxFZcCOvHpWJ4dWDUJv4GigxGQnlVb7Rn02PiVP9(fLFH)GOSBxKVg)Qyg4LpFbMCnjzpchGB30G)coQ7QfVR8LRwuE7t8xnjRPST4685)F8cdl0YI26Q72GBBmQEWFDDEfUh8cZESiFvD11fvZUNpmaEFt5kybHvJ7lr4r5y8K8pQRenelXit9YvfZkZxS(t1vNkAuq4wctsQMIBlAAkM)3P1)T8Yl6KTxVzDXCJgSJi18LFL3bhm7NeRzn4kqu8ZuSIJZwsJ0zobXvFveQz(DXta2S7xaxJAea6cN6WONEsvym2V(PuKH(iQBpdyWh9D))2SU97UO4X8gSiW5o96NQB)urXCQXniYYryTo)OpC0jN(jCn(nairlXVJFLRUV47(P6Y5RXHvmfI)RrM0xYfMsN)(vutIjIgrdClHu3JMmrqHDs9s6QAEXxQVMMOduipWj3A9Jx)yXtnW1bSriILBQVLA6q3utTAbKPy(86hVTUbxeK8QCzbqgSgVDzSIBWEZqZdxJy4ZOwObS4lkXzTd2KHOTf(Oai7jajUULqPPYm5w5xIR5hgMzGEq9(uC2OTih79PCPQ(oCwmcFD90yKWDPU4JymyWfXxCwJKmwNeLjz3TO(rCGzYjeaOpo13SoI6UueTwTzt1bikWuZ8Y2M82Cat6JV9Kt)8hXh7jUBru5trBjLw3oZlgr3BHgFHIFwoXd5wyPACrYnogQ9aZ9Ho77ZFv8UeX1PF3dRBcCH)(okPEQVpz2vrX2PNp1w)hrFH5GGdPU8Y0ep)OId45bhW5iVCovf(CTm39MfWTS5IMxsOFRFa5xbYRGVWggmC)sU7jhMTSU9r(V2ux9BiMgYyRH4U3zcwJVVZAVhWm)y5ACIEHpd2J7TiU1qFEsVA1TW)B4WA8QgGvg3VB85X3OXN4SoxI5MJe1tKNA3M)(unpnRPDcGSvw8LcuKboTAwKVc4Zj6Ujnf4Ouu)ra)NIz0TP1aSoaweuV63tjEIyGmJTFLR20aerxEF5TTx(q5kKAli76z5RWE(88ZeuPS22xvVcNTnCvf9yDZcCe7AUBqEuMFKQ36gYZpRagUCABXsEaliM2bZKJQAKE1Q47v)LoulYrqKmrDMCOpHnb0fIJp13Hqki8)sJxFDHdkAn80O9smovcI8b218uYaN23l(I1jby2tBDB4pq)lhS(6DUi9a0axMdMZEtOS5FHKtE9AK1JG0AAcHwA0UYhU55dqeZ5CfF14QYDWwiElnUaaOebi5299FhV6jCEbBD8dPFhVzn(SZbSZUphkSx9zMTXnDR4w8EfvEkG7vmtdErFLLGWDBmcX02JyFQ71eWpIxOClz8yXWorqwsShicqQDhZJ1npCL7GfcBGhkRmOCOQSGNT6uREpe7ZfGYj6XGaCW)cqT9XnlArMvW1VXisq9E5kUv2jzdKTVfcOR3dIPotVKCnnlh7goexbrvLiaC45jvuFMQDQQbVR(eKVJ4y7yKxJ35AANUjehcroVP(oCghJZibqfd4yAPF8hlRkxMVI0jchER8p7okNOvGCf73sTxpJwaTRoSm6OKkv(GsfBtmiEsmojoEtlOJcknbuN0yMoi2q8FMzmKM9HYBo5ymlE9MC9XBU7sGhEfJ0a2IdinVPj)2wqOWzyiojrrMDbDk1ZRog(s47wmF9XjBC9ShanxHVpRmdMKo4Nna71imTCPQIt2hepG7)TamtmRFeDkmClD08514qJDfOApE7ZfUj30rBaPwu3SrSjeTv9GmpFSgrt5byC(Sw0afbWMzdJ1rj3Y)eDSTWO4oLm1i4hL25ltc6xN)LI5)J66LIoLp3shbj()Rn5nCF9scheJIMd9iMt7UDQdkFoRbegHRocKDXoZUD9A3bwPbVbCbznTOafkaGkUKcukMuMra4UajRwi)yGAXOkN0ZGscviaoBYQ4WyRTgx8ZiTxgSxRhcCBG3iWszw5A46Ht3ACylvu8X6VG3I0noiSvICi2UCxnYg1IDpqc9SFKBCP2N9FHPm4NGyvcy)8cYA1JF(pGvGeODVOfGzs6kgv2SlsEdUZfZbgc(AFVcSmrCzfEiQkEiLI6Sog0RQPiV9NWPfi39uWpdR11tkV92YzWhJkj5ykVOfTqDiZytobW2AbyPs1hZRYVJvzdS5A(sGtMMRc35POJ21jx7hf7LgeDD6eVX0glbRE5vi8A)Pbjjjxhg5liW8I7grSrqGrI7XIZJpjJPt)hrDta18yj0hewehLgfgLWZu7rSnoWZ)WOjt889NmDsaR)00SnTLlkBrZW23M5Ogud8H9JstMegED6(dQPxlFdA52f0RbmVrYcJUnWrWOM1k9cWNa)(Ss3n1Teh53xSyvHXeyh44JVJbfLbOT8iKPx9kKK9qXt3uwbknqKyG2JBAp72lYRUJkCuWWvsat1MLxu)4AzJ)w8LKCM4jyHEOaPwvA(2iiDR3GgYGTSsRscKQ9kCGFrTRAwmbnaWOFx1Lg7o(C3n73bQ7BUtzEei73Qmgu9NFmRTn7PUMnRvUpiksWvQ1Mtkwo4a7NMykhlMERcJPSaD)s1bogUAUYAjTrfEEPPPX(H((W)HYpFyhjwvRXyPjiZy(FcB)nRwHkj9dV5ewUel9qnjz1nkyGppDm7R9P6gs1Z14fHCc6hannxuHIjdWDMjpbIViJmA1FLJaJbXlgavOLUDSNeGW1Zar7rnXte9anj3NEkRQrQmSMdnKvIpqdikHS95fRZbRnH9YzveuI7ZNWjrYNETPoawMgpiLTjITQxhsEThmrHq3j)3Was1SKZeyP6chI0BRtVsT)e6dRWOeb8(QAv(xjMaDDAF1y9x9eO9JblCf6(vat92YvcNQ9y5k10PJBg08gsnt2m0hHB)LceuNdymwz0ZXPn5xaX7LvpiMJQosQkrhRxmyaevBLqGJW1tYbpdvDvPzaxS2Yz5lmMFaScgeTPwRE1EuWZX82suAEdn5LfD0ttpTnn7QZo7dxD65eeuJKPMZD6pIHjwTIFJ2cooM4jcjXqMd)fRHMGf)sRrF0pYS2jg4RfUw8aREzxqqW3)VD1Y9zxJoGqd77G9sKbO6vFCMVEcmSzk88Kv0bFyibe(Mkm9nxaH2zsSacSWhhTeHxdba22GYS9vkDnet)H5QJvfPGQExmYfLzLl(4MeEmvMGn(0SpZQdAWAsiiBVysdQgoGEeDKUTvg2BxMNd22aqwWI2a02rGrhLruZP1by5pg22yiinM88SbEoIP(20Uf9JzhrRdoq7r2QptM5Y(3TTKblwLIQNoukAYuzwHoEgc9CWd3HxG(VBM4obvFn17)BjB8(DHP)q0ZFYHHj4OhWpjm1pGNdAQI(Du65)AWvFRdslMjVWY9xhw8KTIHg2)PAtmwkrP1uFqo8rzKX1)rYF3bdCWwRTAMJndw2AabhFnC2fhEY3SUyXtboQdd3(Ty4o6N7AYk1rf)XY4)pwM8ou)CFyX3DQCswmW248c0qxyTaAZZO0qFV0g3Tf7DCGtmzm7QfO5Tusaih8SSX6uaOEOC2dKhG7P4Utd4Tg(rtfbrwK(cC4ciZXWiEJHxw8xyDU6e)IH1kSJQo7VoIuoVOPLSnW1bfIYA)3H72FKbf9SyCaVLjgkf2o1sasWYI(smQmWnVUfOSfw12olzBQt2ByUUnonwkQ0xVoBbVbz31u)4jLnf0ekhy5FXP)W7r3yoX(60WXE77yJTJ7287pcR6kgU7l1YnspFhc4EzvnQil0wHhc6GmZwy4lgmvsuCRuEOhHhV(AZZTmMKTMmHHXisiSwCN(fu92fZ(XWuYL0PunFbUDgsJkOWSp823HoeW2ZHd63GHXM3hhhyPJUK)GP7NDzPjoVH6htJNl7RbD8HMdcglt(fIXTGu(zW0rNlqBB2bJK1vxfHhY9KW248AKg97oICRPtUw7HtD1P5qhpX3hdZTbV70LlUvosKqbFQwHMBZOYDR5TVzPUcq)o4iTnxKzhraXiWKILOoiao588kO1d2p(OszUthzBR6r233LDcsHoedd5bPHcQHLFW6SQ6Om4uv0HCnXO8TzhDasYUVFGLqwtwkK0L6mkRcNjxDJSLrCF65MuzSmanIU(67UVED71ZMBY6wKJvLR)b8pEmnwDgqLdH6fWs9(Y5ZlQ(U3CcgoHbKZsmADJ5)haR2bca9ZNxRIMxMDH48WXvuN2QEHodDX(ZLvpAJf(B3LDtkTcpVOzDDv(c4sRd64GIoSeRng2RU85MdocJs7pNPIYawpANJxCYc5iKuUeY9AXX13mPFgPl2Ff4a7qwMlPxVc8Chu7vmL(OWanidxB5KVyoTY8TXzq77yi0ZI)KZH38EOzY(Qr4ajVXZLnL7GCnCiYC6P(TPKOJWoS)CV4rhSd80TWfdyi9HYBl(UlZ)Y))Y7AP52ghj8FfFC3dtk8KaK(u28yNu7MzsnX1CyVWs2MXJQLMsLKCQKAQ5)(2paij4dzPeRSQkNlrwceaDJgG9JVUXYM7MX82XbuomshcQnsfj)wnK9qvuCeG2yOnSp1K2VkF79KJXUql1)yNKOf(TBCBIHxPgt8eCS14xrX5puFynCuAkEm2Xov4VNuPW03vtaWtparv)ZA0oTVwxryxjGRWwiAZjH3UR7Qv2ekFPBB9B(Vvu(IeW6vhGS8XCVA7F2O8k7LnAL0RUSXl0w9LnQmdEjq3OZfAFg8)EPwiVSXymImOzW)RSokMUc2V4B7GVILYAOwWjq)8vXR))E4v2wChEhZx1Sl5ltBpLYhizB5XPTJWx(WGch9Ay8EUi2JVKXeMSDiE9Yn4C9N)1F7D)NF9xU6L)Bkf)wwxhAzW9(TDpXRhC3PNobq39Z(3ooOe64drhmG5e4DhKb5XcPBJHuih2JNqmVFXx4BwxmT(g(lDChEgJuUdZbdPZl8AdoKmxG9BdZ)5p3gz5FUAZQLBXIgFye22R2QZ5roIGJ)GVUKvi4gdtYTCpHiM)(4fIqxU7rspKi4GGWYWNbH(kBYr8AYV7gdiY2q6HwI18q0oXARV2dYESzsZ6U0IqcdEcx8QLGe6wrbHxX(t0w0L1q()EOqwRWbYr57XfsoVZx7SxKd3U0tdQNiFS9Ygn59xRRQULUsHJXuMXvkLJIuXULLXiot)ViY9OCtOB9zYbzFq3JQ7X8I1hxZjfwmpluUGW60y2JZSomtlNaUHTr4pygnjxIsV48nNUYY8chI0xYd8yfZA9d1l2GEGoV466vRUTg25q7HrMF8A3nk(WDgUJZAOkeJ24uAe5Hmqt2wvxDdM2jlI5giMyxew(wxDdokYcbjZTPctrdEXfbojS)aAbLfYobLFK3Vy9AqBeckRThjWO1c7sqYOlrjiS1(X6v7OdGYJnGMftNpJD5DvATOoS1vlOygEbYNV4VvDxXfVgZr5Ql(WdBwVAB1FNtIpkHCF5RU6D)(BIdd)oJW5Gi8)E7Mv3)Qx)(3sSiqupWIEptE8v4OUqzZoXuD)CnlqZy(LrJ))3O6StnvZKiW5PCS7CzTgHy)Puc)8BT2uin(t9g7ZpYwxif6NDl2QIt((6ZVLAuc3DQxRphpoZ6Cp7KWX912NHuTYM)CKQFEQsA2ZZ3xFQvo7C8mCv2PEF95hvdAPyoXhMD(r0OLMN6xCDEs1(t8A95NgPOskNAj8ZpQwvCY1c)8JOrJpYo1s4NF7RHJWFwEyw2PwhLZnjCQcbsf4omUo8vYBOU6qfVWxUDBSwdXf4m0BYFyZQpTKRZLbbfPSO8(L3THVH3HVxRrphta3SeZ547AQUL6WTLBQ2wvDB5NLy1CZqnBt19R(m8DHwSBvl4VkXuZaggYr0Ly1YCD5URVUSgtG5BlPSbgDZDOJ4gelOnWdVfAew09kru3JTt2BalVD52Bw1SBzZdqZW01VIQSvjJwD1DlU5R8ul2l4vkimDyeQXJ5MfuLRKjRqherWgseL0Lw7dRl)SgRZC5iuw)iXqq(AF8UXPkCKPfAtJmx48MlBm5(lBucLtEzJvBZ0x2OT6ClfPG5lCjt0JkHnh6WFszKAb(bRfRJhjDJ0wM70kHVuMjr5IUriRukncTqv6K8p1cxx4PKcTY69Lwb9BtJD4zOuLolhNzsmcismETWiWL5nmCFitlgasG5f)1gP)Y)vVNre(lQR0cMW6MIYsLfm62KvQL6ukdM(EN2BSLoZGzVuJ)Kl3v6Zg8qdkFjtWWZYncGQekkKZcHupGB7a2MvPvYsJYNY2804Q8LkLBaZwucmkGv1(B9sUKj5W0w(wWCdRvW6Ok3uMBhqskAqnkyXNMo9yFi1clWkBzw(GPAo9uAyAPPPA3qbsri950Lw1GHYqSC4HGgK(t54dzZezLcqPRbLzMj4YEmI)sP1zjMTXeYv7QVSBZIWUjCwPzjPpwTdlZxOGe1yUMafITgMo9u1HLJt3FHTbw9ES2WBvFKwHZZhRJyQ4rAfjwT32Wv1SYTFT5gSINfjz(CO(vsOjyk8zmaFh2NzTUm(J0jo0NKELK(eifjZ4VmthEcPh5dK82eNOXpqSFXUcpGJ7XMFc2DqNnP8WbEypYrcD8Yy4Lh9wANHw7v)JgpBukTx644T6J5DGuYYYzLKKx3HFgEtJd2ZjbXF4384b6i2wgwgIgf9wAaIrRS79RXqBYh8tv3p89OfYsjv0Hef0T7m9kAUYxXrRLO7396gjSorf0TEOzGPPzdP6uauVnwETXWKRATC4xdvYIVH5IeFnJfbgXmX394NmC0XroKd5qtvDDNlcLJ5E54oT0ynJ5f8Oj7W1HoUT1in5Ttj1bTO5TQFeRzb2KDk20(0iDeBs5SokFP7r2A8uHdGtnqoI18e2QsAj9pwS5vOcsv3QzmfogVxtSrQxn5AkGB1bIi4nxhoWT4jW0a3Qp(SMfexaBdHZbjrhkU4S(19rnIlZ61GUh5kRmpIZQqbj6Pc(wWiaAqzC5WjdbGv1bMQ(aBRd1xmgHouGBPeqx7Ynshok7b5urW4eZkdDra3hF8pwwvJLd9ddixVqM1(pUOiX41lKdHZJuQob2mIt0vXCtH2vhSR64jiKUuoNqNdc)wbJXNVt4DnBbnlGmTaYNsG3pHFPPb1vcE26LInewUgI)QuiCngmB9XU1Sf3Phbex5su8wBaDSZ8HsoWeWoB2uMclYom6sskbT7fWBTi9k5EXMsWZuW63LdvhgQVsWw5ErH58yHCeYVQR(0U4bcewlLkPe0bfnlbnNBcOWImeS2isLn6C)lCCjHFtv9hwTeuyiR4vV5xU6n)2u1FrzXxWeCam7avC35ZfzbBQkWGRJDPDu954y6BsbTIyrUeSt5fh7SJ1(YuuE7Qn3VOz37R2CxfDNuaVMauV6TlR3vrNOw)7zu1ANX02P27dhKtdoupq8OUY4hG3hM51UhSoSIam86RRkU2D0E1WiCgpyNMohmYdu(3Q1EWKafyMLfm8xjmcWSEWQlTc)tPodmrRbmuuRqRcGtYJ(crc2RdBhAmcTh0h5O9gYa3GaDl6DeMOARvdt7WI8mLgSybnO7rmTUZ9d7X(5Hvm2jSCk6ye0djS)noopKe9jsQ)soCpKm23pTvm3HLX1P8dcymxWniKTRmtoXo0X0mzpy0erJ2QCWsV1MRrC9ZwMoLv9839KyIyQi1alatR(TtATBppse9MhFi)(tUHFuPKW(v5BEDDNf8)rn6Mpje2deQNoney1JtvmdnPCO6R91s)WYYGuiJh0s1waMLCH8avovMMoZJvoDusf0PtkswZPr6EG)F)CJ47wHudHm9bPfqI2OjkzoJIOD6pFCAHoR(WpfkJIk8V)uLiv)WhnZ9hRZ8tAwgCe6Bo0CGyE88KLObtPo2Gm0QVAPkX3xXnp4uGXA7XxLvFcVyNyv(w9WU6LnS)zXS2dVdQWe75U6vxVOEIB)P7xD7d8fSX2)eo59V(Fp" },
}

EllesmereUI.WEEKLY_SPOTLIGHT = nil  -- { name = "...", description = "...", exportString = "!EUI_..." }
-- To set a weekly spotlight, uncomment and fill in:
-- EllesmereUI.WEEKLY_SPOTLIGHT = {
--     name = "Week 1 Spotlight",
--     description = "A clean minimal setup",
--     exportString = "!EUI_...",
-- }


-------------------------------------------------------------------------------
--  Initialize profile system on first login
--  Creates the "Default" profile from current settings if none exists.
--  Also saves the active profile on logout (via Lite pre-logout callback)
--  so SavedVariables are current before StripDefaults runs.
-------------------------------------------------------------------------------
do
    -- Register pre-logout callback to persist fonts, colors, and unlock layout
    -- into the active profile, and track the last non-spec profile.
    -- All addons use _dbRegistry (NewDB), so no manual snapshot is needed --
    -- they write directly to the central store.
    EllesmereUI.Lite.RegisterPreLogout(function()
        if not EllesmereUI._profileSaveLocked then
            local db = GetProfilesDB()
            local name = db.activeProfile or "Default"
            local profileData = db.profiles[name]
            if profileData then
                profileData.fonts = DeepCopy(EllesmereUI.GetFontsDB())
                profileData.customColors = DeepCopy(EllesmereUI.GetCustomColorsDB())
                profileData.unlockLayout = {
                    anchors       = DeepCopy(EllesmereUIDB.unlockAnchors     or {}),
                    widthMatch    = DeepCopy(EllesmereUIDB.unlockWidthMatch  or {}),
                    heightMatch   = DeepCopy(EllesmereUIDB.unlockHeightMatch or {}),
                    phantomBounds = DeepCopy(EllesmereUIDB.phantomBounds     or {}),
                }
            end
            -- Track the last active profile that was NOT spec-assigned so
            -- characters without a spec assignment can fall back to it.
            local isSpecAssigned = false
            if db.specProfiles then
                for _, pName in pairs(db.specProfiles) do
                    if pName == name then isSpecAssigned = true; break end
                end
            end
            if not isSpecAssigned then
                db.lastNonSpecProfile = name
            end
        end
    end)

    local initFrame = CreateFrame("Frame")
    initFrame:RegisterEvent("PLAYER_LOGIN")
    initFrame:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_LOGIN")

        local db = GetProfilesDB()

        -- On first install, create "Default" from current (default) settings
        if not db.activeProfile then
            db.activeProfile = "Default"
        end
        -- Ensure Default profile exists (empty table -- NewDB fills defaults)
        if not db.profiles["Default"] then
            db.profiles["Default"] = {}
        end
        -- Ensure Default is in the order list
        local hasDefault = false
        for _, n in ipairs(db.profileOrder) do
            if n == "Default" then hasDefault = true; break end
        end
        if not hasDefault then
            table.insert(db.profileOrder, "Default")
        end

        ---------------------------------------------------------------
        --  Note: multiple specs may intentionally point to the same
        --  profile. No deduplication is performed here.
        ---------------------------------------------------------------

        -- Restore saved profile keybinds
        C_Timer.After(1, function()
            EllesmereUI.RestoreProfileKeybinds()
        end)
    end)
end

-------------------------------------------------------------------------------
--  Shared popup builder for Export and Import
--  Matches the info popup look: dark bg, thin scrollbar, smooth scroll.
-------------------------------------------------------------------------------
local SCROLL_STEP  = 45
local SMOOTH_SPEED = 12

local function BuildStringPopup(title, subtitle, readOnly, onConfirm, confirmLabel)
    local POPUP_W, POPUP_H = 520, 310
    local FONT = EllesmereUI.EXPRESSWAY

    -- Dimmer
    local dimmer = CreateFrame("Frame", nil, UIParent)
    dimmer:SetFrameStrata("FULLSCREEN_DIALOG")
    dimmer:SetAllPoints(UIParent)
    dimmer:EnableMouse(true)
    dimmer:EnableMouseWheel(true)
    dimmer:SetScript("OnMouseWheel", function() end)
    local dimTex = dimmer:CreateTexture(nil, "BACKGROUND")
    dimTex:SetAllPoints()
    dimTex:SetColorTexture(0, 0, 0, 0.25)

    -- Popup
    local popup = CreateFrame("Frame", nil, dimmer)
    popup:SetSize(POPUP_W, POPUP_H)
    popup:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetFrameLevel(dimmer:GetFrameLevel() + 10)
    popup:EnableMouse(true)
    local bg = popup:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.08, 0.10, 1)
    EllesmereUI.MakeBorder(popup, 1, 1, 1, 0.15, EllesmereUI.PanelPP)

    -- Title
    local titleFS = EllesmereUI.MakeFont(popup, 15, "", 1, 1, 1)
    titleFS:SetPoint("TOP", popup, "TOP", 0, -20)
    titleFS:SetText(title)

    -- Subtitle
    local subFS = EllesmereUI.MakeFont(popup, 11, "", 1, 1, 1)
    subFS:SetAlpha(0.45)
    subFS:SetPoint("TOP", titleFS, "BOTTOM", 0, -4)
    subFS:SetText(subtitle)

    -- ScrollFrame containing the EditBox
    local sf = CreateFrame("ScrollFrame", nil, popup)
    sf:SetPoint("TOPLEFT",     popup, "TOPLEFT",     20, -58)
    sf:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -20, 52)
    sf:SetFrameLevel(popup:GetFrameLevel() + 1)
    sf:EnableMouseWheel(true)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(sf:GetWidth() or (POPUP_W - 40))
    sc:SetHeight(1)
    sf:SetScrollChild(sc)

    local editBox = CreateFrame("EditBox", nil, sc)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFont(FONT, 11, "")
    editBox:SetTextColor(1, 1, 1, 0.75)
    editBox:SetPoint("TOPLEFT",     sc, "TOPLEFT",     0, 0)
    editBox:SetPoint("TOPRIGHT",    sc, "TOPRIGHT",   -14, 0)
    editBox:SetHeight(1)  -- grows with content

    -- Scrollbar track
    local scrollTrack = CreateFrame("Frame", nil, sf)
    scrollTrack:SetWidth(4)
    scrollTrack:SetPoint("TOPRIGHT",    sf, "TOPRIGHT",    -2, -4)
    scrollTrack:SetPoint("BOTTOMRIGHT", sf, "BOTTOMRIGHT", -2,  4)
    scrollTrack:SetFrameLevel(sf:GetFrameLevel() + 2)
    scrollTrack:Hide()
    local trackBg = scrollTrack:CreateTexture(nil, "BACKGROUND")
    trackBg:SetAllPoints()
    trackBg:SetColorTexture(1, 1, 1, 0.02)

    local scrollThumb = CreateFrame("Button", nil, scrollTrack)
    scrollThumb:SetWidth(4)
    scrollThumb:SetHeight(60)
    scrollThumb:SetPoint("TOP", scrollTrack, "TOP", 0, 0)
    scrollThumb:SetFrameLevel(scrollTrack:GetFrameLevel() + 1)
    scrollThumb:EnableMouse(true)
    scrollThumb:RegisterForDrag("LeftButton")
    scrollThumb:SetScript("OnDragStart", function() end)
    scrollThumb:SetScript("OnDragStop",  function() end)
    local thumbTex = scrollThumb:CreateTexture(nil, "ARTWORK")
    thumbTex:SetAllPoints()
    thumbTex:SetColorTexture(1, 1, 1, 0.27)

    local scrollTarget = 0
    local isSmoothing  = false
    local smoothFrame  = CreateFrame("Frame")
    smoothFrame:Hide()

    local function UpdateThumb()
        local maxScroll = EllesmereUI.SafeScrollRange(sf)
        if maxScroll <= 0 then scrollTrack:Hide(); return end
        scrollTrack:Show()
        local trackH = scrollTrack:GetHeight()
        local visH   = sf:GetHeight()
        local ratio  = visH / (visH + maxScroll)
        local thumbH = math.max(30, trackH * ratio)
        scrollThumb:SetHeight(thumbH)
        local scrollRatio = (tonumber(sf:GetVerticalScroll()) or 0) / maxScroll
        scrollThumb:ClearAllPoints()
        scrollThumb:SetPoint("TOP", scrollTrack, "TOP", 0, -(scrollRatio * (trackH - thumbH)))
    end

    smoothFrame:SetScript("OnUpdate", function(_, elapsed)
        local cur = sf:GetVerticalScroll()
        local maxScroll = EllesmereUI.SafeScrollRange(sf)
        scrollTarget = math.max(0, math.min(maxScroll, scrollTarget))
        local diff = scrollTarget - cur
        if math.abs(diff) < 0.3 then
            sf:SetVerticalScroll(scrollTarget)
            UpdateThumb()
            isSmoothing = false
            smoothFrame:Hide()
            return
        end
        sf:SetVerticalScroll(cur + diff * math.min(1, SMOOTH_SPEED * elapsed))
        UpdateThumb()
    end)

    local function SmoothScrollTo(target)
        local maxScroll = EllesmereUI.SafeScrollRange(sf)
        scrollTarget = math.max(0, math.min(maxScroll, target))
        if not isSmoothing then isSmoothing = true; smoothFrame:Show() end
    end

    sf:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = EllesmereUI.SafeScrollRange(self)
        if maxScroll <= 0 then return end
        SmoothScrollTo((isSmoothing and scrollTarget or self:GetVerticalScroll()) - delta * SCROLL_STEP)
    end)
    sf:SetScript("OnScrollRangeChanged", function() UpdateThumb() end)

    -- Thumb drag
    local isDragging, dragStartY, dragStartScroll
    local function StopDrag()
        if not isDragging then return end
        isDragging = false
        scrollThumb:SetScript("OnUpdate", nil)
    end
    scrollThumb:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        isSmoothing = false; smoothFrame:Hide()
        isDragging = true
        local _, cy = GetCursorPosition()
        dragStartY      = cy / self:GetEffectiveScale()
        dragStartScroll = sf:GetVerticalScroll()
        self:SetScript("OnUpdate", function(self2)
            if not IsMouseButtonDown("LeftButton") then StopDrag(); return end
            isSmoothing = false; smoothFrame:Hide()
            local _, cy2 = GetCursorPosition()
            cy2 = cy2 / self2:GetEffectiveScale()
            local trackH   = scrollTrack:GetHeight()
            local maxTravel = trackH - self2:GetHeight()
            if maxTravel <= 0 then return end
            local maxScroll = EllesmereUI.SafeScrollRange(sf)
            local newScroll = math.max(0, math.min(maxScroll,
                dragStartScroll + ((dragStartY - cy2) / maxTravel) * maxScroll))
            scrollTarget = newScroll
            sf:SetVerticalScroll(newScroll)
            UpdateThumb()
        end)
    end)
    scrollThumb:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then StopDrag() end
    end)

    -- Reset on hide
    dimmer:HookScript("OnHide", function()
        isSmoothing = false; smoothFrame:Hide()
        scrollTarget = 0
        sf:SetVerticalScroll(0)
        editBox:ClearFocus()
    end)

    -- Auto-select for export (read-only): click selects all for easy copy.
    -- For import (editable): just re-focus so the user can paste immediately.
    if readOnly then
        editBox:SetScript("OnMouseUp", function(self)
            C_Timer.After(0, function() self:SetFocus(); self:HighlightText() end)
        end)
        editBox:SetScript("OnEditFocusGained", function(self)
            self:HighlightText()
        end)
    else
        editBox:SetScript("OnMouseUp", function(self)
            self:SetFocus()
        end)
        -- Click anywhere in the scroll area should also focus the editbox
        sf:SetScript("OnMouseDown", function()
            editBox:SetFocus()
        end)
    end

    if readOnly then
        editBox:SetScript("OnChar", function(self)
            self:SetText(self._readOnly or ""); self:HighlightText()
        end)
    end

    -- Resize scroll child to fit editbox content
    local function RefreshHeight()
        C_Timer.After(0.01, function()
            local lineH = (editBox.GetLineHeight and editBox:GetLineHeight()) or 14
            local h = editBox:GetNumLines() * lineH
            local sfH = sf:GetHeight() or 100
            -- Only grow scroll child beyond the visible area when content is taller
            if h <= sfH then
                sc:SetHeight(sfH)
                editBox:SetHeight(sfH)
            else
                sc:SetHeight(h + 4)
                editBox:SetHeight(h + 4)
            end
            UpdateThumb()
        end)
    end
    editBox:SetScript("OnTextChanged", function(self, userInput)
        if readOnly and userInput then
            self:SetText(self._readOnly or ""); self:HighlightText()
        end
        RefreshHeight()
    end)

    -- Buttons
    if onConfirm then
        local confirmBtn = CreateFrame("Button", nil, popup)
        confirmBtn:SetSize(120, 26)
        confirmBtn:SetPoint("BOTTOMRIGHT", popup, "BOTTOM", -4, 14)
        confirmBtn:SetFrameLevel(popup:GetFrameLevel() + 2)
        EllesmereUI.MakeStyledButton(confirmBtn, confirmLabel or "Import", 11,
            EllesmereUI.WB_COLOURS, function()
                local str = editBox:GetText()
                if str and #str > 0 then
                    dimmer:Hide()
                    onConfirm(str)
                end
            end)

        local cancelBtn = CreateFrame("Button", nil, popup)
        cancelBtn:SetSize(120, 26)
        cancelBtn:SetPoint("BOTTOMLEFT", popup, "BOTTOM", 4, 14)
        cancelBtn:SetFrameLevel(popup:GetFrameLevel() + 2)
        EllesmereUI.MakeStyledButton(cancelBtn, "Cancel", 11,
            EllesmereUI.RB_COLOURS, function() dimmer:Hide() end)
    else
        local closeBtn = CreateFrame("Button", nil, popup)
        closeBtn:SetSize(120, 26)
        closeBtn:SetPoint("BOTTOM", popup, "BOTTOM", 0, 14)
        closeBtn:SetFrameLevel(popup:GetFrameLevel() + 2)
        EllesmereUI.MakeStyledButton(closeBtn, "Close", 11,
            EllesmereUI.RB_COLOURS, function() dimmer:Hide() end)
    end

    -- Dimmer click to close
    dimmer:SetScript("OnMouseDown", function()
        if not popup:IsMouseOver() then dimmer:Hide() end
    end)

    -- Escape to close
    popup:EnableKeyboard(true)
    popup:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            dimmer:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    return dimmer, editBox, RefreshHeight
end

-------------------------------------------------------------------------------
--  Export Popup
-------------------------------------------------------------------------------
function EllesmereUI:ShowExportPopup(exportStr)
    local dimmer, editBox, RefreshHeight = BuildStringPopup(
        "Export Profile",
        "Copy the string below and share it",
        true, nil, nil)

    editBox._readOnly = exportStr
    editBox:SetText(exportStr)
    RefreshHeight()

    dimmer:Show()
    C_Timer.After(0.05, function()
        editBox:SetFocus()
        editBox:HighlightText()
    end)
end

-------------------------------------------------------------------------------
--  Import Popup
-------------------------------------------------------------------------------
function EllesmereUI:ShowImportPopup(onImport)
    local dimmer, editBox = BuildStringPopup(
        "Import Profile",
        "Paste an EllesmereUI profile string below",
        false,
        function(str) if onImport then onImport(str) end end,
        "Import")

    dimmer:Show()
    C_Timer.After(0.05, function() editBox:SetFocus() end)
end
