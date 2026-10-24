-- Depends on all other AbundanceTally files, loaded last per the TOC.
-- SavedVariables initialization, slash command registration and the /tally
-- handler.
local ADDON_NAME, ns = ...

SLASH_ABUNDANCETALLY1 = "/tally"
-- /tally is short enough to be contested by another addon; SlashCmdList
-- registration is last-writer-wins, so this full-length fallback is never lost.
SLASH_ABUNDANCETALLY2 = "/abundancetally"

local function PrintHelp()
    ns.Print("commands:")
    ns.Print("  /tally probe - record Abundance game data (/tally probe help for its commands)")
    ns.Print("  /tally version - show the addon version")
    ns.Print("  /tally help - list all commands")
end

SlashCmdList.ABUNDANCETALLY = function(msg)
    local command, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command = command:lower()

    if command == "probe" then
        ns.Probe.HandleCommand(rest)
    elseif command == "version" then
        ns.Print("version %s", ns.GetVersion())
    else
        PrintHelp()
    end
end

-- SavedVariables are only guaranteed populated once ADDON_LOADED fires for
-- this addon; initializing earlier would create a throwaway table that the
-- client's own load then discards.
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, _, loadedAddon)
    if loadedAddon ~= ADDON_NAME then
        return
    end
    AbundanceTallyDB = AbundanceTallyDB or {}
    ns.Probe.OnAddonLoaded()
    self:UnregisterEvent("ADDON_LOADED")
end)
