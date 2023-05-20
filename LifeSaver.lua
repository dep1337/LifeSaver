-----------------------------------------------------------------------------
--  World of Warcraft addOn to display a player's combat damage
--
--  (c) May 2023 Duncan Baxter & Jennifer Kennedy
--
--  License: All available rights reserved to the authors
-----------------------------------------------------------------------------
-- SECTION 1: Constant/Variable definitions
-----------------------------------------------------------------------------
-- General
local addonName = "LifeSaver"
local playerGUID -- player's GUID (used to filter combat log events)

-- Fonts
local fontName = "NumberFont_Shadow_Med"
local fontHeight = floor(select(2, _G[fontName]:GetFont()) + 0.5)
--print(_G[fontName]:GetJustifyV())

-- Sizes of objects
local iconSize = 96 -- Width and height of each icon
local gap = fontHeight/2 -- Free space around and between objects
local barHeight = fontHeight + gap -- Height of player's health bar

-- Create objects
local frame = CreateFrame("Frame", addonName, UIParent, "SimplePanelTemplate") -- Frame defined in SharedXML/SharedUIPanelTemplates.xml
	frame.titleDTPS = frame:CreateFontString(nil, "OVERLAY", fontName)
	frame.amountDTPS = frame:CreateFontString(nil, "OVERLAY", fontName)
	frame.spellName = frame:CreateFontString(nil, "OVERLAY", fontName)
	frame.icon = frame:CreateTexture(nil, "ARTWORK", nil, -8)
	frame.mask = frame:CreateTexture(nil, "ARTWORK", nil, -7)
	frame.titleDMG = frame:CreateFontString(nil, "OVERLAY", fontName)
	frame.amountDMG = frame:CreateFontString(nil, "OVERLAY", fontName)
	frame.bar = CreateFrame("StatusBar", nil, frame)
		frame.health = frame.bar:CreateFontString(nil, "OVERLAY", fontName)
	frame.button = CreateFrame("Button", nil, frame, "MagicButtonTemplate") -- Button defined in SharedXML/SharedUIPanelTemplates.xml
local timer -- Currently unused (see commented-out text in events:COMBAT_LOG_EVENT_UNFILTERED())

-- Set the position and size of the frame (leave room for the widgets within frame.Inset)
local left, top = select(4, frame.Inset:GetPointByName("TOPLEFT"))
local right, bottom = select(4, frame.Inset:GetPointByName("BOTTOMRIGHT"))
local width = left + (2 * gap) + iconSize - right -- Width of the parent frame
local height = -top + (5 * gap) + iconSize + (3 * fontHeight) + barHeight + bottom -- Height of the parent frame

-- Collect some text strings into a handy table
local text = {
	tooltip = addonName .. ":\nEvery frame should have a tooltip.  This is mine.",
	loaded = addonName .. ": Ready for pull-timer ...",
	logout = addonName .. ": Run away, little girl ...",
}

-- Icons for the ENVIRONMENTAL_DAMAGE subevent (which does not provide one)
local damageIcon = {}
	damageIcon.Drowning = 1385912
	damageIcon.Falling = 132301
	damageIcon.Fatigue = 136090
	damageIcon.Fire = 135805
	damageIcon.Lava = 237583
	damageIcon.Slime = 134437

-- Array of field names for the payload to COMBAT_LOG_EVENT_UNFILTERED (currently unused)
local payloadKey = {timestamp,	subevent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, 
	spellId, spellName, spellSchool, 
	amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing, isOffHand, environmentalType }

-- Array of timestamps and damage over the last few seconds' worth of COMBAT_LOG_EVENT_UNFILTERED events
local DTPS = {} -- Time series used to calculate average DTPS over the last few seconds (weighted towards more recent damage)
local fade = 2 -- Period over which to fade out the display (after each COMBAT_LOG_EVENT_UNFILTERED event)
local durationDTPS = 5 -- Include the last 5 seconds of damage in the DTPS calculation

-----------------------------------------------------------------------------
-- SECTION 1.1: Debugging utilities 
-----------------------------------------------------------------------------
-- Debugging function to recursively print the contents of a table (eg. a frame)
local function dumpTable(tbl, lvl) -- Parameters are the table(tbl) and (optionally) a prefix for each line (default is ".")
	if (type(lvl) ~= "string") then lvl = "." end
	for k, v in pairs(tbl) do 
		print(format("%s%s = %s", lvl, k, tostring(v)))
		if (type(v) == "table") then 
			dumpTable(v, lvl .. k .. ".")
		end
	end
end

-- Print out the payload from a COMBAT_LOG_EVENT_UNFILTERED event
local function dumpCLEU(payload)
	local fields = getn(payload)
	print(format("dumpCLEU: Found %d elements in the payload array", fields))
	for i = 1, fields do
		print(format("[%d]: %s", i, tostring(payload[i])))
	end
	print("dumpCLEU: Finished")
end

--------------------------------------------------------------------------------------
-- SECTION 2.1: Callback and support functions for the parent frames and child widgets
--------------------------------------------------------------------------------------
-- Initialise icon and font strings (also occurs after a few seconds with no damage - see events:COMBAT_LOG_EVENT_UNFILTERED())
-- Currently unused because, due to frame fadeout, these values would never be seen
local function initialiseWidgets()
	frame.icon:SetTexture(133712) -- Happy party bomb icon signifying no damage over the last few seconds
	frame.amountDTPS:SetText("0")
	frame.spellName:SetText("No Damage")
	frame.amountDMG:SetText("0")
	frame:Hide()
end

-- Set up the damage icon (center of the frame)
local function setIcon()
	local icon = frame.icon
	icon:SetPoint("TOPLEFT", frame.Inset.Bg, "TOPLEFT", gap, -(2 * (fontHeight + gap)))
	icon:SetSize(iconSize, iconSize)

	local mask = frame.mask -- Nice yellow frame to tidy-up the damage icon
	mask:SetPoint("CENTER", frame.icon)
	mask:SetSize(iconSize, iconSize)
	mask:SetAtlas("talents-node-choiceflyout-square-yellow", false)
end

-- Set up the player's health bar (bottom of the frame)
local function setHealth()
	local bar = frame.bar
	bar:SetOrientation("HORIZONTAL")
	bar:SetPoint("TOPLEFT", frame.Inset.Bg, "BOTTOMLEFT", gap, barHeight + gap)
	bar:SetPoint("BOTTOMRIGHT", frame.Inset.Bg, "BOTTOMRIGHT", -gap, gap)
	bar:SetStatusBarTexture("_Legionfall_BarFill_UnderConstruction", "ARTWORK", -8)
	bar:SetRotatesTexture(false)

	bar.health = 0
	bar.maxHealth = 0
	bar.red = -1 -- This impossible value ensures that updateHealth() will treat the initial state as a change
	bar.green = 0
	bar.blue = 0
end	

-- Set up FontStrings for total DTPS, damage name (or source), damage amount and player's health percentage
local function setFontStrings()
	local fs = frame.titleDTPS
	fs:SetPoint("TOPLEFT", frame, "TOPLEFT", left + gap, -(4 + gap))
	fs:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", left + gap, -(4 + gap + fontHeight))
	fs:SetText("DTPS:")

	local fs = frame.amountDTPS
	fs:SetPoint("TOPRIGHT", frame, "TOPRIGHT", right - gap, -(4 + gap))
	fs:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", right - gap, -(4 + gap + fontHeight))

	fs = frame.spellName
	fs:SetPoint("TOPLEFT", frame.Inset.Bg, "TOPLEFT", 0, 0)
	fs:SetPoint("BOTTOMRIGHT", frame.Inset.Bg, "TOPRIGHT", 0, -(2 * (fontHeight + gap)))

	fs = frame.titleDMG
	fs:SetPoint("TOPLEFT", frame.icon, "BOTTOMLEFT", 0, -gap)
	fs:SetPoint("BOTTOMLEFT", frame.icon, "BOTTOMLEFT", 0, -(gap + fontHeight))
	fs:SetText("Damage:")

	fs = frame.amountDMG
	fs:SetPoint("TOPRIGHT", frame.icon, "BOTTOMRIGHT", 0, -gap)
	fs:SetPoint("BOTTOMRIGHT", frame.icon, "BOTTOMRIGHT", 0, -(gap + fontHeight))

	fs = frame.health
	fs:SetPoint("TOPLEFT", frame.bar, "TOPLEFT", gap/2, 0)
	fs:SetPoint("BOTTOMLEFT", frame.bar, "BOTTOMLEFT", gap/2, 0)
end

-- Set up the larger Close button (bottom of the frame)
local function setButton()
	local button = frame.button
	button:SetPoint("BOTTOM", frame, "BOTTOM", 0, 4)
	button:SetText("Close")
	button:SetScript("OnClick", function(self, mouseButton, down) frame:Hide() end)
end

-- Get the current health and maximum health of the player, then update the health bar as required
local function updateHealth()
	local bar = frame.bar
	local health = UnitHealth("player")
	local maxHealth = UnitHealthMax("player")
	
	if (health ~= bar.health) or (maxHealth ~= bar.maxHealth) then -- We need to re-draw the bar
		local red, green, blue
		local h = (health * 100) / maxHealth
		if (h > 85) then 
			red, green, blue = 0, 132/255, 80/255 -- Above 85% health, bar is Traffic Light Green
		elseif (h > 25) then 
			red, green, blue = 1, 192/255, 0 -- Between 25% and 85% health, bar is Traffic Light Amber
		else 
			red, green, blue = 187/255, 30/255, 16/255 -- At 25% health (and below), bar is Traffic Light Red
		end

		if (red ~= bar.red) then -- We need to re-colour the bar
			bar.red = red
			bar.green = green
			bar.blue = blue
			bar:SetStatusBarColor(red, green, blue, 1)
		end

		if (maxHealth ~= bar.maxHealth) then
			bar.maxHealth = maxHealth
			bar:SetMinMaxValues(0, maxHealth)
		end

		if (health ~= bar.health) then
			bar.health = health
			bar:SetValue(health)
		end

		frame.health:SetText(format("%u%%", h))
	end
end

-----------------------------------------------------------------------------
-- SECTION 2.2: Set up the parent frame
-----------------------------------------------------------------------------
-- Make the frame draggable
frame:SetMovable(true)
frame:SetScript("OnMouseDown", function(self, button) self:StartMoving() end)
frame:SetScript("OnMouseUp", function(self, button) self:StopMovingOrSizing() end)

-- Display the mouseover tooltip
frame:SetScript("OnEnter", function(self, motion)
	GameTooltip:SetOwner(self, "ANCHOR_PRESERVE") -- Allegedly keeps the tooltip text in its default position
	GameTooltip:AddLine(text.tooltip)
	GameTooltip:Show()
end)
frame:SetScript("OnLeave", function(self, motion) GameTooltip:Hide() end)

-----------------------------------------------------------------------------
-- SECTION 3: Event handlers
-----------------------------------------------------------------------------
-- SECTION 3.1: Callback and support functions for the event handlers
-----------------------------------------------------------------------------
-- Update "Damage Taken Per Second" (over the last few seconds)
local function updateDTPS(timestamp, amount)
	tinsert(DTPS, {timestamp, amount}) -- Add new time/damage pair to the set

	local now = GetServerTime()	-- Remove expired damage (ie. more than a few seconds old) from the set 
	while ((now - DTPS[1][1]) > durationDTPS) do
		tremove(DTPS, 1)
	end

	local total, base = 0, 0 -- Calculate weighted average damage over the last few seconds
	local weight
	for i, v in ipairs(DTPS) do
		weight = durationDTPS - (now - v[1]) -- Weight recent damage more heavily than older damage
		total = total + (weight * v[2])
		base = base + weight
	end
	return floor(0.5 + (total / base)) -- Round the result to the nearest integer
end

-----------------------------------------------------------------------------
-- SECTION 3.2: Event handlers
-----------------------------------------------------------------------------
local events = {}

-- Process combat log damage events that affect the player
function events:COMBAT_LOG_EVENT_UNFILTERED()
	local payload = {CombatLogGetCurrentEventInfo()}
	if (payload[8] == playerGUID) and ((strsub(payload[2], -6) == "DAMAGE")) then
		local eventTime = payload[1]
		local subevent = payload[2]

		if (subevent == "SWING_DAMAGE") then
			frame.amountDTPS:SetText(updateDTPS(eventTime, payload[12]))
			local found
			if (payload[3]) then frame.spellName:SetText("Hidden Caster")
			else 
				frame.spellName:SetText(payload[5])
				local nameplates = C_NamePlate.GetNamePlates()
				for i, v in ipairs(nameplates) do
					if (UnitGUID(nameplates[i].namePlateUnitToken) == payload[4]) then
						found = nameplates[i].namePlateUnitToken
						break
					end
				end
			end
			if (found) then SetPortraitTexture(frame.icon, found, true) 
			else frame.icon:SetTexture(237274) -- Skull icon signifying source of damage is hidden
			end
			frame.amountDMG:SetText(payload[12])
			frame.mask:SetVertexColor(1, 1, 1) -- Yellow frame for SWING_DAMAGE

		elseif (subevent == "ENVIRONMENTAL_DAMAGE") then
			frame.amountDTPS:SetText(updateDTPS(eventTime, payload[13]))
			frame.spellName:SetText(payload[12])
			frame.icon:SetTexture(damageIcon[payload[12]])
			frame.amountDMG:SetText(payload[13])
			frame.mask:SetVertexColor(1, 0, 0) -- Red frame for ENVIRONMENTAL_DAMAGE

		else 
			frame.amountDTPS:SetText(updateDTPS(eventTime, payload[15]))
			frame.spellName:SetText(payload[13])
			frame.icon:SetTexture(select(3, GetSpellInfo(payload[12])))
			frame.amountDMG:SetText(payload[15])
			if (subevent == "SPELL_PERIODIC_DAMAGE") then frame.mask:SetVertexColor(1, 0, 0) -- Red frame
			else frame.mask:SetVertexColor(1, 1, 1) -- Yellow frame for RANGE_DAMAGE and SPELL_DAMAGE
			end
		end
--	if (timer) then timer:Cancel() end -- Cancel any existing timer 
--	timer = C_Timer.NewTimer(durationDTPS, function() initialiseWidgets() end) -- Set a new timer to clear the display after a few seconds
--	frame:Show()
	UIFrameFadeOut(frame, fade, 1, 0)
	end
end

-- Fires when the addon finishes loading (saved variables should now be available)
function events:ADDON_LOADED(name)
	if (name == addonName) then
--	dumpTable(frame)
		
		if (frame:GetNumPoints() == 0) then 
			frame:SetPoint("CENTER")
			frame:SetSize(width, height)
		end

		setIcon()
		setHealth()
		setFontStrings()
--		initialiseWidgets()
		setButton()
		frame:Hide()

		frame:UnregisterEvent("ADDON_LOADED")
		print(text.loaded)
	end
end

-- Fires *after* ADDON_LOADED and PLAYER_LOGIN (player health data should now be available)
function events:PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUI)
	if (lsReports) then 
		print("Login: ", isInitialLogin, "Reload: ", isReloadingUI)
	end
	playerGUID = UnitGUID("player")
	updateHealth()
end

-- Update health bar to reflect a change in a character's current health
function events:UNIT_HEALTH(unitTarget)
	if (unitTarget == "player") then updateHealth() end
end

-- Update health bar to reflect a change in a character's maximum health
function events:UNIT_MAXHEALTH(unitTarget)
	if (unitTarget == "player") then updateHealth() end
end

function events:PLAYER_LOGOUT()
	frame:UnregisterAllEvents()
	print(text.logout)
end

-- Register all the events for which we have a separate handling function
frame:SetScript("OnEvent", function(self, event, ...) events[event](self, ...) end)
for k, v in pairs(events) do frame:RegisterEvent(k) end

-----------------------------------------------------------------------------
-- SECTION 4: Set our slash commands
-----------------------------------------------------------------------------
local slash = {} -- Table of handlers for slash commands (NB: handler function names must be in lower case)
local helptext = {} -- Table of helptext for each slash command

-- Show the parent frame
slash.show = function ()
	frame:Show()
end
helptext.show = "Show the parent frame"

-- Hide the parent frame
slash.hide = function () 
	frame:Hide()
end
helptext.hide = "Hide the parent frame (equivalent to pressing either 'close' button)"

-- Reset the position of the parent frame
slash.reset = function ()
	frame:ClearAllPoints()
	frame:SetPoint("CENTER")
	frame:SetSize(width, height)
end
helptext.reset = "Reset the position of the parent frame"

-- Display the player's standing with the Obsidian Warders or Dark Talons (as the case may be)
-- This is only here because the standard UI does not make this information available
slash.renown = function ()
	local faction
	if (UnitFactionGroup("player") == "Alliance") then faction = 2524 -- Faction ID 2524 is the Obsidian Warders
	else faction = 2523 end -- Faction ID 2523 is the Dark Talons
	local name, description, standingID, barMin, barMax, barValue = GetFactionInfoByID(faction)
	print(format("%s:\n%s", name, description))
	print(format("Standing: %s", _G["FACTION_STANDING_LABEL" .. standingID]))
	if (barValue < barMax) then 
		print(format("Progress to %s: %d/%d", _G["FACTION_STANDING_LABEL" .. standingID + 1], (barValue - barMin), (barMax - barMin))) 
	end
end
helptext.renown = "Display the player's standing with the Obsidian Warders or Dark Talons"

-- Print helptext for each slash command
slash.help = function ()
	print(format("Slash commands for %s:", addonName))
	print(format("Use /%s or /%s (either upper or lower case, or a combination of the two)\n\n", strlower(addonName), strlower(strsub(addonName, 1, 2))))
	local order = {"show", "hide", "reset", "renown", "help"} -- Order in which to print the slash commands and their helptext
	for i, v in pairs(order) do
		print(format("/%s %s = %s", strlower(strsub(addonName, 1, 2)), v, helptext[v]))
	end
	print("\n")
end
helptext.help = "Print this helptext ('h' and '?' also work)"

-- Define the callback handler for our slash commands
local function cbSlash(msg, editBox)
	local cmd = strlower(msg)
	if (cmd == "?") or (cmd == "h") then cmd = "help" end
	if (slash[cmd] == nil) then print(addonName .. ": Unknown slash command (" .. msg .. ")")
	else
		slash[cmd]()
		print(addonName .. ": Processed (" .. msg .. ") command")
	end
end

-- Add our slash commands and callback handler to the global table
_G["SLASH_" .. strupper(addonName) .. "1"] = "/" .. strlower(strsub(addonName, 1, 2))
_G["SLASH_" .. strupper(addonName) .. "2"] = "/" .. strupper(strsub(addonName, 1, 2))
_G["SLASH_" .. strupper(addonName) .. "3"] = "/" .. strlower(addonName)
_G["SLASH_" .. strupper(addonName) .. "4"] = "/" .. strupper(addonName)

SlashCmdList[strupper(addonName)] = cbSlash
