#version 2

-- Jetpack (Multiplayer)
-- Based on the built-in Jetpack by Tuxedo Labs.
--
-- The server does the actual flying (thrust, fuel, limits). Clients handle
-- sound, exhaust effects, the fuel gauge and the settings screen.
-- Saved settings live under savegame.mod.* and keep their names between
-- versions so nobody loses their setup on update.
--
-- 28.0: custom profile slots, per-player overrides, hover assist, boost,
--       flight modes (Classic / Hover / Glide), upgrades, flight stats,
--       gauge options and a settings-change message for everyone.
--       English only: all translations were removed.
-- 28.1: small HUD extras (client side only): speed unit (m/s, km/h, mph)
--       and an altitude readout. Nothing in the server logic changed.
-- 28.1 revision 2: host can hide the settings menu from players, expert
--       limits (title tap ladder: locked > extended > expert > locked),
--       Comfort tab (menu key, reopen on last tab, resets), optional
--       silence for settings messages, wider ranges when expert is on.
-- 28.3: settings menu rebuilt. Extended range and expert limits are gone
--       (one set of ranges for everybody) and the 12 tabs became 7, grouped
--       as Game (Flight, Fuel & Boost), Host tools (Players, Admin) and
--       You (Controls, HUD, Stats). New host tools: block a single player
--       without setting up approval mode first, reset one player's
--       overrides, clear every override, reset flight stats.
--       Saved settings keep their names; old extended / expert values are
--       simply clamped to the normal ranges.

local VERSION = "28.3"
local REVISION = 1

local THRUST_BASE = 0.3        -- velocity added per physics step at 100%
local SOUND_VOLUME = 0.5
local THRUST_DEFAULT = 100

local FUEL_MIN, FUEL_MAX, FUEL_DEFAULT = 2, 30, 6   -- tank size in seconds
local REFILL_DEFAULT, REFILL_MIN, REFILL_MAX, REFILL_STEP = 2.5, 1, 10, 0.5   -- seconds for a full refill
local FUEL_SYNC_INTERVAL = 0.2
local FUEL_SNAP_DISTANCE = 0.5

local RAMP_SECONDS = 0.35      -- time to reach full thrust after take-off
local RAMP_FLOOR = 0.15        -- thrust at the very first step
local CAP_MIN, CAP_MAX, CAP_STEP = 10, 60, 5        -- speed cap in m/s, 0 = none

local DELAY_MIN, DELAY_MAX, DELAY_STEP, DELAY_DEFAULT = 0, 5, 0.5, 0   -- seconds on the ground before refuelling starts
local CEIL_MIN, CEIL_MAX, CEIL_STEP = 10, 200, 10    -- height limit above the ground in metres, 0 = none

local BIND_RESEND = 3          -- seconds between flight key updates to the server
local GAUGE_HIDE_DELAY = 3
local GAUGE_FADE_RATE = 6


-- shared helpers ------------------------------------------------------

local function thrustLimits()
	return 50, 150, 10
end

local function clampThrust(v)
	local lo, hi, step = thrustLimits()
	v = tonumber(v) or THRUST_DEFAULT
	v = math.floor(v / step + 0.5) * step
	return math.max(lo, math.min(hi, v))
end

local function clampFuel(v)
	v = math.floor((tonumber(v) or FUEL_DEFAULT) + 0.5)
	return math.max(FUEL_MIN, math.min(FUEL_MAX, v))
end

local function clampCap(v)
	v = tonumber(v) or 0
	if v <= 0 then return 0 end
	v = math.floor(v / CAP_STEP + 0.5) * CAP_STEP
	return math.max(CAP_MIN, math.min(CAP_MAX, v))
end

local function clampRefill(v)
	v = tonumber(v) or REFILL_DEFAULT
	v = math.floor(v / REFILL_STEP + 0.5) * REFILL_STEP
	return math.max(REFILL_MIN, math.min(REFILL_MAX, v))
end

local function clampDelay(v)
	v = tonumber(v) or DELAY_DEFAULT
	v = math.floor(v / DELAY_STEP + 0.5) * DELAY_STEP
	return math.max(DELAY_MIN, math.min(DELAY_MAX, v))
end

local function clampCeiling(v)
	v = tonumber(v) or 0
	if v <= 0 then return 0 end
	v = math.floor(v / CEIL_STEP + 0.5) * CEIL_STEP
	return math.max(CEIL_MIN, math.min(CEIL_MAX, v))
end

-- One-click setups used by the host tab. The server applies them itself.
local PROFILES = {
	original = { thrust = 100, cap = 0,  smooth = true,  fuel = false, tank = FUEL_DEFAULT },
	balanced = { thrust = 100, cap = 25, smooth = true,  fuel = true,  tank = 8 },
	turbo    = { thrust = 150, cap = 40, smooth = false, fuel = false, tank = FUEL_DEFAULT },
}
local PROFILE_ORDER = { "original", "balanced", "turbo" }

local function sameList(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

local function isGrounded(p)
	if not IsPlayerValid(p) then return false end
	local pos = GetPlayerTransform(p).pos
	local hit, dist = QueryRaycast(Vec(pos[1], pos[2] + 0.25, pos[3]), Vec(0, -1, 0), 0.4)
	return hit and dist <= 0.4
end

-- Thrust pushes harder the longer you hold it, so a tap doesn't kick you.
local function rampPower(held)
	local s = math.min(1, held / RAMP_SECONDS)
	return RAMP_FLOOR + (1 - RAMP_FLOOR) * s * s * (3 - 2 * s)
end

-- Thrust may not take you above the cap, but it never slows you down either.
local function capSpeed(oldVel, newVel, cap)
	if cap <= 0 then return newVel end
	local newSpeed = VecLength(newVel)
	local limit = math.max(cap, VecLength(oldVel))
	if newSpeed <= limit then return newVel end
	return VecScale(newVel, limit / newSpeed)
end


-- inputs the server is willing to read for a player ---------------------

local VALID_INPUTS = {}
for _, name in ipairs({
	"jump", "crouch", "interact", "flashlight", "grab", "usetool",
	"space", "shift", "ctrl", "alt", "tab", "rmb", "mmb", "return", "backspace",
	"uparrow", "downarrow", "leftarrow", "rightarrow",
	"home", "end", "pgup", "pgdown", "insert", "delete",
}) do
	VALID_INPUTS[name] = true
end
for c = string.byte("a"), string.byte("z") do VALID_INPUTS[string.char(c)] = true end
for d = 0, 9 do VALID_INPUTS[tostring(d)] = true end
for f = 1, 12 do VALID_INPUTS["f" .. f] = true end

-- ids saved by older versions
local LEGACY_INPUTS = { sprint = "shift" }

local function normalizeBind(bind)
	bind = LEGACY_INPUTS[bind] or bind
	if VALID_INPUTS[bind] then return bind end
	return nil
end

local function inputHeld(name, player)
	local ok, down
	if player then
		ok, down = pcall(InputDown, name, player)
	else
		ok, down = pcall(InputDown, name)
	end
	return ok and down
end



-- 28.0 constants and helpers ---------------------------------------------

local BOOST_TIME, BOOST_MUL = 0.4, 2.6        -- burst length and thrust factor
local BOOST_CD_MIN, BOOST_CD_MAX, BOOST_CD_DEFAULT = 3, 30, 8
local BOOST_COST_MAX, BOOST_COST_STEP, BOOST_COST_DEFAULT = 5, 0.5, 1.5
local GLIDE_THRUST, GLIDE_SINK = 0.55, 2.5    -- glide: forward push, slowest fall (m/s)
local MUL_MIN, MUL_STEP, MUL_T_MAX, MUL_F_MAX = 25, 25, 200, 400   -- per-player overrides

local MODE_COUNT = 3                           -- 1 classic, 2 hover, 3 glide

local function clampMul(v, hi)
	v = tonumber(v) or 100
	v = math.floor(v / MUL_STEP + 0.5) * MUL_STEP
	return math.max(MUL_MIN, math.min(hi, v))
end

local function clampBoostCd(v)
	v = math.floor((tonumber(v) or BOOST_CD_DEFAULT) + 0.5)
	return math.max(BOOST_CD_MIN, math.min(BOOST_CD_MAX, v))
end

local function clampBoostCost(v)
	v = tonumber(v) or BOOST_COST_DEFAULT
	v = math.floor(v / BOOST_COST_STEP + 0.5) * BOOST_COST_STEP
	return math.max(0, math.min(BOOST_COST_MAX, v))
end

-- Upgrades unlock with lifetime flight time (seconds). Bonus is a fraction.
local UPGRADES = {
	{ id = "tank",   name = "Tank",   at = { 60, 240, 720 },  bonus = { 0.15, 0.30, 0.50 } },
	{ id = "thrust", name = "Thrust", at = { 90, 360, 1080 }, bonus = { 0.05, 0.10, 0.15 } },
	{ id = "refill", name = "Refill", at = { 120, 480, 1440 }, bonus = { 0.25, 0.50, 0.75 } },
}

local function upTier(up, seconds)
	local tier = 0
	for i = 1, #up.at do
		if seconds >= up.at[i] then tier = i end
	end
	return tier
end

local function upBonus(up, seconds, enabled)
	if not enabled then return 0 end
	local tier = upTier(up, seconds)
	return tier > 0 and up.bonus[tier] or 0
end

local PROFILE_NAMES = {
	original = "Original", balanced = "Balanced", turbo = "Turbo",
	custom1 = "Custom 1", custom2 = "Custom 2",
}

local function describeProfile(p)
	local capText = p.cap == 0 and "no speed cap" or (p.cap .. " m/s cap")
	local fuelText = p.fuel and ("fuel " .. p.tank .. " s") or "unlimited fuel"
	return string.format("thrust %d%%, %s, %s", p.thrust, capText, fuelText)
end

local MODE_NAMES = { "Classic", "Hover", "Glide" }


do  -- server scope

-- server --------------------------------------------------------------

local lastJetting = {}
local lastBoosting = {}
local thrustPct = THRUST_DEFAULT
local jetpackOn = true
local speedCap = 0
local smoothStart = true
local restrictOn = false          -- this one is per session on purpose
local allowed = {}                -- [playerId] = true
local lastPlayerCount = 0
local errorShown = false

local fuelOn = false
local refillSeconds = REFILL_DEFAULT
local hostFree = false                -- host never runs out of fuel; per session on purpose
local fuelCap = FUEL_DEFAULT
local fuel = {}                   -- [playerId] = seconds left
local fuelTimer = 0
local lastFuelValues = {}
local refillDelay = DELAY_DEFAULT     -- seconds on the ground before the tank starts to refill
local ceilingM = 0                    -- height limit above the ground, 0 = none
local baseY = {}                      -- [playerId] = height of the ground they last stood on
local groundedFor = {}                -- [playerId] = seconds on the ground without flying

local binds = {}                  -- [playerId] = input name
local boostBinds = {}             -- [playerId] = input name for the boost
local ramp = {}                   -- [playerId] = seconds of continuous thrust

-- 28.0
local flightMode = 1              -- 1 classic, 2 hover, 3 glide
local hoverOn = true              -- hover assist (flight + crouch)
local boostOn = false
local boostCooldown = BOOST_CD_DEFAULT
local boostCost = BOOST_COST_DEFAULT
local upgradesOn = false
local ovT, ovF = {}, {}           -- per-player thrust / endurance overrides in percent (per session)
local boostCd, boostLeft, boostPrev = {}, {}, {}
local stats = {}                  -- [playerId] = { peak, dist, time, boosts, key, dirty }
local airborne, lastX, lastZ = {}, {}, {}
local lastStats = {}
local statsTimer, saveTimer = 0, 0
local noteSeq = 0
local menuHidden, announceOn = false, true

local function notify(text, force)
	if not announceOn and not force then return end
	noteSeq = noteSeq + 1
	shared.noteText = text
	shared.noteSeq = noteSeq
end

local function publishAllowed()
	local list = {}
	for pid, on in pairs(allowed) do
		if on and IsPlayerValid(pid) then
			list[#list + 1] = pid
		else
			allowed[pid] = nil
		end
	end
	table.sort(list)
	shared.allowed = list
end

local function publishFuel(force)
	local ids, values = {}, {}
	local players = GetAllPlayers()
	for i = 1, #players do
		local p = players[i]
		ids[i] = p
		values[i] = math.floor((fuel[p] or fuelCap) * 10 + 0.5) / 10
	end
	if force or not sameList(values, lastFuelValues) or #ids ~= #(shared.fuelIds or {}) then
		shared.fuelIds = ids
		shared.fuelVals = values
		lastFuelValues = values
	end
end

-- flat list: player, thrust %, endurance % (only players with an override)
local function publishMuls()
	local list = {}
	for _, p in ipairs(GetAllPlayers()) do
		local t, f = ovT[p] or 100, ovF[p] or 100
		if t ~= 100 or f ~= 100 then
			list[#list + 1] = p
			list[#list + 1] = t
			list[#list + 1] = f
		end
	end
	shared.pm = list
end

-- stats are kept per player name in the host's save, so they survive sessions
local function statKey(p)
	local ok, name = pcall(GetPlayerName, p)
	name = ok and tostring(name) or ""
	name = name:gsub("[^%w]", ""):sub(1, 20)
	if name == "" then name = "player" end
	return "savegame.mod.st." .. name
end

local function statsFor(p)
	local s = stats[p]
	if s then return s end
	local key = statKey(p)
	s = {
		key = key, dirty = false,
		peak = GetInt(key .. ".peak"), dist = GetInt(key .. ".dist"),
		time = GetInt(key .. ".time"), boosts = GetInt(key .. ".boosts"),
	}
	stats[p] = s
	return s
end

local function saveStat(s)
	if not s or not s.dirty then return end
	s.dirty = false
	SetInt(s.key .. ".peak", math.floor(s.peak))
	SetInt(s.key .. ".dist", math.floor(s.dist))
	SetInt(s.key .. ".time", math.floor(s.time))
	SetInt(s.key .. ".boosts", s.boosts)
end

local function publishStats(force)
	local list = {}
	for _, p in ipairs(GetAllPlayers()) do
		local s = stats[p]
		if s then
			local i = #list
			list[i + 1] = p
			list[i + 2] = math.floor(s.peak)
			list[i + 3] = math.floor(s.dist)
			list[i + 4] = math.floor(s.time)
			list[i + 5] = s.boosts
		end
	end
	if force or not sameList(list, lastStats) then
		shared.ps = list
		lastStats = list
	end
end

local function forgetLeftPlayers()
	for pid, s in pairs(stats) do
		if not IsPlayerValid(pid) then saveStat(s) end
	end
	for _, store in ipairs({ binds, boostBinds, fuel, ramp, baseY, groundedFor, ovT, ovF,
			boostCd, boostLeft, boostPrev, stats, airborne, lastX, lastZ }) do
		for pid in pairs(store) do
			if not IsPlayerValid(pid) then store[pid] = nil end
		end
	end
	publishAllowed()
	publishMuls()
end

local function canFly(p)
	if not jetpackOn then return false end
	if restrictOn and not IsPlayerHost(p) and not allowed[p] then return false end
	return true
end

local function publishCustom(slot)
	local p = PROFILES["custom" .. slot]
	if not p then
		shared["custom" .. slot] = {}
		return
	end
	shared["custom" .. slot] = { p.thrust, p.cap, p.smooth and 1 or 0, p.fuel and 1 or 0, p.tank }
end

function server.init()
	menuHidden = GetInt("savegame.mod.menu_hidden") == 1
	announceOn = GetInt("savegame.mod.quiet") ~= 1
	jetpackOn = GetInt("savegame.mod.disabled") ~= 1
	smoothStart = GetInt("savegame.mod.noramp") ~= 1
	speedCap = clampCap(GetInt("savegame.mod.speedcap"))

	local savedThrust = GetInt("savegame.mod.thrustpct")
	if savedThrust > 0 then thrustPct = clampThrust(savedThrust) end

	fuelOn = GetInt("savegame.mod.fuel_enabled") == 1
	local savedTank = GetInt("savegame.mod.fuel_cap")
	fuelCap = savedTank > 0 and clampFuel(savedTank) or FUEL_DEFAULT

	local savedRefill = GetInt("savegame.mod.refill_x10")
	if savedRefill > 0 then refillSeconds = clampRefill(savedRefill / 10) end

	refillDelay = clampDelay(GetInt("savegame.mod.refill_delay_x10") / 10)
	ceilingM = clampCeiling(GetInt("savegame.mod.ceiling"))

	-- 28.0
	local savedMode = GetInt("savegame.mod.flight_mode")
	if savedMode >= 1 and savedMode <= MODE_COUNT then flightMode = savedMode end
	hoverOn = GetInt("savegame.mod.hover_off") ~= 1
	boostOn = GetInt("savegame.mod.boost_on") == 1
	local savedCd = GetInt("savegame.mod.boost_cd")
	if savedCd > 0 then boostCooldown = clampBoostCd(savedCd) end
	local savedCost = GetInt("savegame.mod.boost_cost_x10")
	if savedCost > 0 or GetInt("savegame.mod.boost_cost_set") == 1 then
		boostCost = clampBoostCost(savedCost / 10)
	end
	upgradesOn = GetInt("savegame.mod.upgrades_on") == 1

	for slot = 1, 2 do
		local k = "savegame.mod.custom" .. slot
		if GetInt(k .. "_set") == 1 then
			PROFILES["custom" .. slot] = {
				thrust = clampThrust(GetInt(k .. "_thrust")),
				cap = clampCap(GetInt(k .. "_cap")),
				smooth = GetInt(k .. "_smooth") == 1,
				fuel = GetInt(k .. "_fuel") == 1,
				tank = clampFuel(GetInt(k .. "_tank")),
			}
		end
		publishCustom(slot)
	end

	shared.thrustPct = thrustPct
	shared.enabled = jetpackOn
	shared.menuHidden = menuHidden
	shared.announce = announceOn
	shared.speedCap = speedCap
	shared.smooth = smoothStart
	shared.fuelEnabled = fuelOn
	shared.fuelCap = fuelCap
	shared.refill = refillSeconds
	shared.refillDelay = refillDelay
	shared.ceiling = ceilingM
	shared.hostFree = false
	shared.fuelIds = {}
	shared.fuelVals = {}
	shared.restrict = false
	shared.allowed = {}
	shared.jetting = {}
	shared.boosting = {}
	shared.mode = flightMode
	shared.hover = hoverOn
	shared.boostOn = boostOn
	shared.boostCd = boostCooldown
	shared.boostCost = boostCost
	shared.upgrades = upgradesOn
	shared.pm = {}
	shared.ps = {}
	shared.noteSeq = 0
	shared.noteText = ""
end

-- Everything below is called from the host's settings screen. The server
-- clamps every value itself, whatever the client sent.

function server.setThrustPct(pct)
	thrustPct = clampThrust(pct)
	shared.thrustPct = thrustPct
	SetInt("savegame.mod.thrustpct", thrustPct)
end

function server.setEnabled(on)
	jetpackOn = on and true or false
	shared.enabled = jetpackOn
	SetInt("savegame.mod.disabled", jetpackOn and 0 or 1)
end

-- Players can't open Jetpack Settings at all while this is on.
function server.setMenuHidden(on, silent)
	menuHidden = on and true or false
	shared.menuHidden = menuHidden
	SetInt("savegame.mod.menu_hidden", menuHidden and 1 or 0)
	if silent ~= true then
		notify(menuHidden and "Host hid the Jetpack settings menu" or "Host showed the Jetpack settings menu", true)
	end
end

-- Whether changes are announced on everyone's screen.
function server.setAnnounce(on, silent)
	if not on and silent ~= true then notify("Host turned settings messages off", true) end
	announceOn = on and true or false
	shared.announce = announceOn
	SetInt("savegame.mod.quiet", announceOn and 0 or 1)
	if announceOn and silent ~= true then notify("Host turned settings messages on") end
end

function server.setSpeedCap(cap)
	speedCap = clampCap(cap)
	shared.speedCap = speedCap
	SetInt("savegame.mod.speedcap", speedCap)
end

function server.setSmooth(on)
	smoothStart = on and true or false
	shared.smooth = smoothStart
	SetInt("savegame.mod.noramp", smoothStart and 0 or 1)
end

function server.setFuelEnabled(on)
	fuelOn = on and true or false
	shared.fuelEnabled = fuelOn
	SetInt("savegame.mod.fuel_enabled", fuelOn and 1 or 0)
	fuel = {}
	lastFuelValues = {}
	shared.fuelIds = {}
	shared.fuelVals = {}
	if fuelOn then publishFuel(true) end
end

function server.setFuelCap(cap)
	fuelCap = clampFuel(cap)
	shared.fuelCap = fuelCap
	SetInt("savegame.mod.fuel_cap", fuelCap)
	for pid, amount in pairs(fuel) do
		if amount > fuelCap then fuel[pid] = fuelCap end
	end
end

function server.setRestrict(on)
	restrictOn = on and true or false
	shared.restrict = restrictOn
	publishAllowed()
end

function server.setAllowed(pid, on)
	if type(pid) ~= "number" or not IsPlayerValid(pid) then return end
	allowed[pid] = on and true or nil
	publishAllowed()
end

function server.setAllowedAll(on)
	for _, p in ipairs(GetAllPlayers()) do
		if not IsPlayerHost(p) then allowed[p] = on and true or nil end
	end
	publishAllowed()
end

function server.setRefill(seconds)
	refillSeconds = clampRefill(seconds)
	shared.refill = refillSeconds
	SetInt("savegame.mod.refill_x10", math.floor(refillSeconds * 10 + 0.5))
end

function server.setRefillDelay(seconds)
	refillDelay = clampDelay(seconds)
	shared.refillDelay = refillDelay
	SetInt("savegame.mod.refill_delay_x10", math.floor(refillDelay * 10 + 0.5))
end

function server.setCeiling(metres)
	ceilingM = clampCeiling(metres)
	shared.ceiling = ceilingM
	SetInt("savegame.mod.ceiling", ceilingM)
end

function server.setHostFree(on)
	hostFree = on and true or false
	shared.hostFree = hostFree
end

function server.refillAll()
	if not fuelOn then return end
	local players = GetAllPlayers()
	for i = 1, #players do fuel[players[i]] = fuelCap end
	publishFuel(true)
end

function server.refillPlayer(pid)
	if not fuelOn or type(pid) ~= "number" or not IsPlayerValid(pid) then return end
	fuel[pid] = fuelCap
	publishFuel(true)
end

-- 28.3: host tools

-- Blocking one player while everyone can fly switches approval mode on and
-- approves everybody else, so only that player is stopped.
function server.setPlayerFlight(pid, on)
	if type(pid) ~= "number" or not IsPlayerValid(pid) or IsPlayerHost(pid) then return end
	if on then
		allowed[pid] = true
	else
		if not restrictOn then
			for _, p in ipairs(GetAllPlayers()) do
				if not IsPlayerHost(p) then allowed[p] = true end
			end
			restrictOn = true
			shared.restrict = true
		end
		allowed[pid] = nil
	end
	publishAllowed()
end

function server.resetPlayer(pid)
	if type(pid) ~= "number" then return end
	ovT[pid], ovF[pid] = nil, nil
	publishMuls()
end

function server.resetOverrides()
	ovT, ovF = {}, {}
	publishMuls()
	notify("Host cleared all player overrides")
end

-- Flight stats drive the upgrades, so this resets those tiers too.
function server.resetStats()
	for _, p in ipairs(GetAllPlayers()) do
		local s = statsFor(p)
		s.peak, s.dist, s.time, s.boosts = 0, 0, 0, 0
		s.dirty = true
		saveStat(s)
	end
	publishStats(true)
	notify("Host reset flight stats")
end

-- 28.0: flight mode, hover assist, boost, upgrades, per-player overrides

function server.setMode(mode)
	mode = math.floor(tonumber(mode) or 1)
	if mode < 1 or mode > MODE_COUNT then return end
	flightMode = mode
	shared.mode = mode
	SetInt("savegame.mod.flight_mode", mode)
	notify("Host set the flight mode to " .. MODE_NAMES[mode])
end

function server.setHover(on)
	hoverOn = on and true or false
	shared.hover = hoverOn
	SetInt("savegame.mod.hover_off", hoverOn and 0 or 1)
end

function server.setBoostOn(on)
	boostOn = on and true or false
	shared.boostOn = boostOn
	SetInt("savegame.mod.boost_on", boostOn and 1 or 0)
	notify(boostOn and "Host turned boost on" or "Host turned boost off")
end

function server.setBoostCd(seconds)
	boostCooldown = clampBoostCd(seconds)
	shared.boostCd = boostCooldown
	SetInt("savegame.mod.boost_cd", boostCooldown)
end

function server.setBoostCost(seconds)
	boostCost = clampBoostCost(seconds)
	shared.boostCost = boostCost
	SetInt("savegame.mod.boost_cost_x10", math.floor(boostCost * 10 + 0.5))
	SetInt("savegame.mod.boost_cost_set", 1)
end

function server.setUpgrades(on)
	upgradesOn = on and true or false
	shared.upgrades = upgradesOn
	SetInt("savegame.mod.upgrades_on", upgradesOn and 1 or 0)
	notify(upgradesOn and "Host turned upgrades on" or "Host turned upgrades off")
end

function server.setPlayerMul(pid, kind, pct)
	if type(pid) ~= "number" or not IsPlayerValid(pid) then return end
	if kind == "thrust" then
		ovT[pid] = clampMul(pct, MUL_T_MAX)
	elseif kind == "fuel" then
		ovF[pid] = clampMul(pct, MUL_F_MAX)
	else
		return
	end
	publishMuls()
end

function server.applyProfile(name, silent)
	local p = PROFILES[name]
	if not p then return end
	server.setThrustPct(p.thrust)
	server.setSpeedCap(p.cap)
	server.setSmooth(p.smooth)
	server.setFuelCap(p.tank)
	server.setFuelEnabled(p.fuel)
	if silent ~= true then
		notify("Host applied " .. (PROFILE_NAMES[name] or name) .. ": " .. describeProfile(p))
	end
end

-- Stores the current flight setup in a custom slot (1 or 2).
function server.saveCustom(slot)
	slot = math.floor(tonumber(slot) or 0)
	if slot ~= 1 and slot ~= 2 then return end
	local p = { thrust = thrustPct, cap = speedCap, smooth = smoothStart, fuel = fuelOn, tank = fuelCap }
	PROFILES["custom" .. slot] = p
	local k = "savegame.mod.custom" .. slot
	SetInt(k .. "_set", 1)
	SetInt(k .. "_thrust", p.thrust)
	SetInt(k .. "_cap", p.cap)
	SetInt(k .. "_smooth", p.smooth and 1 or 0)
	SetInt(k .. "_fuel", p.fuel and 1 or 0)
	SetInt(k .. "_tank", p.tank)
	publishCustom(slot)
end

-- Back to how the mod ships. Personal (client side) settings are not touched.
function server.resetAll()
	server.setAnnounce(true, true)
	server.setMenuHidden(false, true)
	server.setEnabled(true)
	server.applyProfile("original", true)
	server.setRefill(REFILL_DEFAULT)
	server.setRefillDelay(DELAY_DEFAULT)
	server.setCeiling(0)
	server.setHostFree(false)
	server.setMode(1)
	server.setHover(true)
	server.setBoostOn(false)
	server.setBoostCd(BOOST_CD_DEFAULT)
	server.setBoostCost(BOOST_COST_DEFAULT)
	server.setUpgrades(false)
	ovT, ovF = {}, {}
	publishMuls()
	allowed = {}
	server.setRestrict(false)
	notify("Host reset all Jetpack settings")
end

-- each client tells us which inputs it flies and boosts with
function server.setPlayerBind(pid, bind, boostBind)
	if type(pid) ~= "number" or not IsPlayerValid(pid) then return end
	bind = normalizeBind(bind)
	if bind then binds[pid] = bind end
	boostBind = normalizeBind(boostBind)
	if boostBind then boostBinds[pid] = boostBind end
end

function server.tick(dt)
	pcall(function()
		local count = GetPlayerCount()
		if count ~= lastPlayerCount then
			lastPlayerCount = count
			forgetLeftPlayers()
		end
	end)
end

local function stepPlayers(dt)
	local flying, boosting = {}, {}
	local players = GetAllPlayers()

	for i = 1, #players do
		local p = players[i]
		local s = statsFor(p)
		local health = GetPlayerHealth(p)
		local inVehicle = GetPlayerVehicle(p) ~= 0
		local free = hostFree and IsPlayerHost(p)

		if fuelOn then
			if fuel[p] == nil or health <= 0 or free then
				fuel[p] = fuelCap                 -- new player or respawn
			elseif fuel[p] > fuelCap then
				fuel[p] = fuelCap
			end
		end

		local endurance = (ovF[p] or 100) / 100 * (1 + upBonus(UPGRADES[1], s.time, upgradesOn))
		local thrustMul = (ovT[p] or 100) / 100 * (1 + upBonus(UPGRADES[2], s.time, upgradesOn))
		local refillMul = 1 + upBonus(UPGRADES[3], s.time, upgradesOn)

		local wantsToFly = canFly(p) and health > 0 and not inVehicle
			and inputHeld(binds[p] or "jump", p)
		local hasFuel = not fuelOn or free or fuel[p] > 0.02
		local flyingNow = wantsToFly and hasFuel

		local pos = GetPlayerTransform(p).pos
		local grounded = inVehicle or isGrounded(p)

		-- Ground the player last stood on: height limit and peak height use it.
		if grounded or health <= 0 or baseY[p] == nil then baseY[p] = pos[2] end
		local ceilRoom = nil               -- metres left below the limit
		if ceilingM > 0 then ceilRoom = ceilingM - (pos[2] - baseY[p]) end

		-- Boost: a rising edge on the boost key while flying, if the cooldown is over.
		local boostHeld = boostOn and inputHeld(boostBinds[p] or "q", p) or false
		boostCd[p] = math.max(0, (boostCd[p] or 0) - dt)
		if flyingNow and boostHeld and not boostPrev[p] and boostCd[p] <= 0 then
			local affordable = not fuelOn or free or boostCost <= 0 or fuel[p] >= boostCost
			if affordable then
				boostLeft[p] = BOOST_TIME
				boostCd[p] = boostCooldown
				if fuelOn and not free then fuel[p] = math.max(0, fuel[p] - boostCost) end
				s.boosts = s.boosts + 1
				s.dirty = true
			end
		end
		boostPrev[p] = boostHeld

		if flyingNow then
			groundedFor[p] = 0
			ramp[p] = (ramp[p] or 0) + dt
			s.time = s.time + dt
			s.dirty = true

			local power = smoothStart and rampPower(ramp[p]) or 1
			local boostK, capK = 1, 1
			if (boostLeft[p] or 0) > 0 then
				boostLeft[p] = boostLeft[p] - dt
				boostK, capK, power = BOOST_MUL, 1.5, 1
				boosting[#boosting + 1] = p
			end

			local t = THRUST_BASE * thrustPct / 100 * thrustMul * power * boostK
			local vel = GetPlayerVelocity(p)
			local push
			if flightMode == 2 then
				push = Vec(0, t, 0)                                     -- hover: straight up
			elseif flightMode == 3 then
				push = TransformToParentVec(GetPlayerCameraTransform(p), Vec(0, 0, -t * GLIDE_THRUST))
			else
				push = TransformToParentVec(GetPlayerCameraTransform(p), Vec(0, t, 0))
			end

			local assist = hoverOn and inputHeld("crouch", p)
			if assist then push = Vec(push[1], 0, push[3]) end

			local newVel = capSpeed(vel, VecAdd(vel, push), speedCap * capK)
			if assist then
				-- Pull the vertical speed towards what cancels the next step of gravity.
				local vy = newVel[2]
				newVel = Vec(newVel[1], vy + (10 * dt - vy) * math.min(1, dt * 14), newVel[3])
			elseif flightMode == 3 and newVel[2] < -GLIDE_SINK then
				newVel = Vec(newVel[1], -GLIDE_SINK, newVel[3])
			end
			if ceilRoom then
				-- Slow the climb so gravity alone would stop you right at the limit.
				local vmax = ceilRoom > 0 and math.sqrt(2 * 10 * ceilRoom) or 0
				if newVel[2] > vmax then newVel = Vec(newVel[1], vmax, newVel[3]) end
			end
			SetPlayerVelocity(newVel, p)
			flying[#flying + 1] = p
			if fuelOn and not free then fuel[p] = math.max(0, fuel[p] - dt / endurance) end
		else
			ramp[p] = math.max(0, (ramp[p] or 0) - dt * 3)
			boostLeft[p] = 0
			if grounded then groundedFor[p] = (groundedFor[p] or 0) + dt else groundedFor[p] = 0 end
			if fuelOn and grounded and groundedFor[p] >= refillDelay then
				fuel[p] = math.min(fuelCap, fuel[p] + dt * fuelCap / refillSeconds * refillMul)
			end
		end

		-- Flight stats: peak height above take-off and horizontal distance while airborne.
		if flyingNow then airborne[p] = true end
		if grounded or health <= 0 then airborne[p] = false end
		local moved = 0
		if lastX[p] then moved = math.sqrt((pos[1] - lastX[p]) ^ 2 + (pos[3] - lastZ[p]) ^ 2) end
		lastX[p], lastZ[p] = pos[1], pos[3]
		if airborne[p] and moved < 20 then
			s.dist = s.dist + moved
			local h = pos[2] - baseY[p]
			if h > s.peak then s.peak = h end
			s.dirty = true
		end
	end

	-- only touch shared when something changed
	if not sameList(flying, lastJetting) then
		shared.jetting = flying
		lastJetting = flying
	end
	if not sameList(boosting, lastBoosting) then
		shared.boosting = boosting
		lastBoosting = boosting
	end

	if fuelOn then
		fuelTimer = fuelTimer + dt
		if fuelTimer >= FUEL_SYNC_INTERVAL then
			fuelTimer = 0
			publishFuel(false)
		end
	end

	statsTimer = statsTimer + dt
	if statsTimer >= 0.5 then
		statsTimer = 0
		publishStats(false)
	end
	saveTimer = saveTimer + dt
	if saveTimer >= 10 then
		saveTimer = 0
		for _, s in pairs(stats) do saveStat(s) end
	end
end

function server.update(dt)
	local ok, err = pcall(stepPlayers, dt)
	if not ok and not errorShown then
		errorShown = true
		DebugPrint("Jetpack (Multiplayer) server error: " .. tostring(err))
	end
end


end  -- server scope

local function buildClient()  -- client scope (keeps each function under Lua's local limit)

-- text (English only) -----------------------------------------------------

local STRINGS = {
	-- window
	title = "Jetpack Settings", host_view = "Host settings", player_view = "Player view",
	host_stats = "%d players   -   %d flying", close = "Close", on = "On", off = "Off",
	version_line = "Version %s   -   Revision %d",
	hint_pad = "Confirm: select    Cancel: close    LB / RB: tabs",
	host_only_note = "Only the host can change these settings.",
	not_allowed = "The host has not allowed you to use the jetpack.",

	-- sidebar
	sec_game = "Game", sec_host = "Host tools", sec_you = "You",
	tab_flight = "Flight", tab_fuel = "Fuel & Boost", tab_players = "Players", tab_admin = "Admin",
	tab_controls = "Controls", tab_hud = "HUD", tab_stats = "Stats",

	-- flight
	jetpack = "Jetpack", jetpack_sub = "Turn the jetpack on or off for everyone",
	mode_title = "Flight mode",
	mode_classic = "Classic", mode_hover = "Hover", mode_glide = "Glide",
	mode_classic_d = "Thrust follows where you look",
	mode_hover_d = "Straight up and down only",
	mode_glide_d = "Slow fall and forward drift",
	thrust = "Thrust", thrust_sub = "%d%% - %d%%, where 100%% is the original",
	speed_cap = "Speed cap", speed_cap_sub = "The fastest the jetpack can push you",
	speed_value = "%d m/s", speed_off = "No limit",
	ceiling = "Height limit", ceiling_sub = "How far above the ground the jetpack can lift you",
	smooth = "Smooth take-off", smooth_sub = "Thrust builds up gently instead of starting at full power",
	hover_assist = "Hover assist", hover_assist_sub = "Hold flight and crouch to cancel vertical drift",

	-- fuel and boost
	fuel_system = "Fuel system", fuel_sub = "Flying drains a tank. Standing on the ground refills it.",
	tank = "Tank size", tank_sub = "%d - %d seconds of flying",
	refill_time = "Refill time", refill_time_sub = "How long a full refill takes on the ground",
	refill_delay = "Refill delay", refill_delay_sub = "Time on the ground before the tank starts to refill",
	boost = "Boost", boost_sub = "A short burst on a second key. Costs extra fuel.",
	boost_cd = "Cooldown", boost_cost = "Extra fuel",
	upgrades = "Upgrades", upgrades_sub = "Tank, thrust and refill tiers unlock with flight time",

	-- players (host)
	approval = "Approval mode", approval_on_sub = "Only players marked Can fly can use the jetpack",
	approval_off_sub = "Everyone can fly. Blocking a player turns approval mode on.",
	allow_all = "Allow all", block_all = "Block all",
	can_fly = "Can fly", blocked = "Blocked", host = "Host", refill = "Refill",
	row_peak = "Peak %s", row_thrust = "Thrust", row_fuel = "Endurance", reset = "Reset",

	-- admin (host)
	profiles = "Quick profiles", profiles_sub = "One click setups for flight and fuel",
	profile_original = "Original", profile_balanced = "Balanced", profile_turbo = "Turbo",
	custom_1 = "Custom 1", custom_2 = "Custom 2", save_to = "Save current setup to",
	toast_applied = "Applied %s", toast_saved = "Saved current setup as %s",
	host_free = "Host flies freely", host_free_sub = "You never run out of fuel. Resets when the session ends.",
	menu_hidden = "Hide settings menu", menu_hidden_sub = "Players no longer see this menu. You always do.",
	announce = "Settings messages", announce_sub = "Tell everyone when you change a setting",
	refill_all = "Refill everyone", clear_overrides = "Clear overrides",
	reset_stats = "Reset stats", reset_all = "Reset all", confirm_short = "Confirm?",
	toast_refilled = "Everyone's tank is full", toast_cleared = "Player overrides cleared",
	toast_stats_reset = "Flight stats and upgrades reset", toast_all_reset = "All host settings reset",

	-- controls
	flight_key = "Flight key",
	key_sub_kb = "Click the button, then press a key",
	key_sub_pad = "Pick the action that makes you fly",
	press_key = "Press a key...", clear = "Clear", kb_only = "Keyboard only",
	key_in_use = "That key is already used for flying or boost",
	boost_key = "Boost key", boost_key_sub = "Press it while flying for a short burst",
	menu_key = "Menu key", menu_key_sub = "Open and close this menu without pausing", menu_key_none = "Not set",
	effects = "Exhaust effects", effects_sub = "Flames and smoke behind jetpacks",
	fx_off = "Off", fx_light = "Flames", fx_full = "Full",
	accent = "Accent colour", accent_sub = "Buttons and highlights",
	last_tab = "Reopen on last tab", last_tab_sub = "Open this menu where you left it",
	reset_personal = "Reset my settings", reset_personal_sub = "Keys, effects, accent and HUD. Host settings stay.",
	toast_personal_reset = "Personal settings reset",

	-- hud
	gauge = "Auto-hide fuel gauge", gauge_sub = "Fade the gauge out after a few seconds on the ground",
	speed_hud = "Speed readout", speed_hud_sub = "Show your current speed on screen",
	alt_hud = "Altitude readout", alt_hud_sub = "Show your height above the ground",
	speed_unit = "Speed unit", unit_ms = "m/s", unit_kmh = "km/h", unit_mph = "mph",
	gauge_size = "Gauge size", size_s = "Small", size_m = "Medium", size_l = "Large",
	gauge_pos = "Gauge position", pos_bottom = "Bottom", pos_top = "Top", pos_left = "Left", pos_right = "Right",
	gauge_color = "Gauge colour", color_default = "Default", color_cb = "Colourblind",

	-- stats
	stat_peak = "PEAK HEIGHT", stat_peak_sub = "above take-off",
	stat_dist = "DISTANCE FLOWN", stat_dist_sub = "all time",
	stat_time = "FLIGHT TIME", stat_boosts = "%d boosts",
	up_title = "Upgrades", up_off = "Off - the host can enable them under Fuel & Boost",
	up_tier = "Tier %d   +%d%%", up_locked = "Locked", up_max = "MAX",
	pilots = "Pilots", pilots_more = "Pilots (+%d more)",
	col_peak = "PEAK", col_dist = "DISTANCE", col_time = "TIME",

	-- in game
	hud_fuel = "FUEL  %.1fs", hud_empty = "FUEL EMPTY",
	boost_ready = "BOOST READY", boost_wait = "BOOST  %ds", alt_value = "ALT %d m",

	-- key names
	act_jump = "Jump", act_crouch = "Crouch", act_interact = "Interact",
	act_flashlight = "Flashlight", act_grab = "Grab", act_usetool = "Use tool",
	key_space = "Space", key_shift = "Shift", key_ctrl = "Ctrl", key_alt = "Alt",
	key_tab = "Tab", key_rmb = "Right click", key_mmb = "Middle click",
}

local function T(key, ...)
	local text = STRINGS[key] or key
	if select("#", ...) > 0 then
		local ok, out = pcall(string.format, text, ...)
		if ok then return out end
	end
	return text
end

local function fmtDist(m)
	if m >= 1000 then return string.format("%.2f km", m / 1000) end
	return string.format("%d m", math.floor(m))
end

local function fmtTime(s)
	s = math.floor(s)
	if s >= 3600 then
		return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60)
	end
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- flat lists published by the server
local function listIndex(list, stride, pid)
	if not list then return nil end
	for i = 1, #list, stride do
		if list[i] == pid then return i end
	end
	return nil
end

local function getOverrides(pid)
	local list = shared.pm
	local i = listIndex(list, 3, pid)
	if i then return list[i + 1], list[i + 2] end
	return 100, 100
end

local function getStats(pid)
	local list = shared.ps
	local i = listIndex(list, 5, pid)
	if i then return list[i + 1], list[i + 2], list[i + 3], list[i + 4] end
	return 0, 0, 0, 0
end

-- how long a tank lasts and how fast it refills for a player, as multipliers
local function fuelMultipliers(pid)
	local _, ovFuel = getOverrides(pid)
	local _, _, time = getStats(pid)
	local on = shared.upgrades == true
	return ovFuel / 100 * (1 + upBonus(UPGRADES[1], time, on)), 1 + upBonus(UPGRADES[3], time, on)
end

local function listHas(list, pid)
	if not list then return false end
	for i = 1, #list do
		if list[i] == pid then return true end
	end
	return false
end


-- client: state and input ----------------------------------------------

local PAD_ACTIONS = { "jump", "crouch", "interact", "flashlight", "grab" }
local PAD_VALID = {}
for _, name in ipairs(PAD_ACTIONS) do PAD_VALID[name] = true end

local snd = 0
local settingsOpen = false
local openedAt = 0
local tab = "flight"
local lastTab = "flight"             -- tab the menu was last left on
-- tab ids saved by older versions
local LEGACY_TABS = {
	general = "flight", modes = "flight", extras = "fuel", personal = "controls", comfort = "controls",
	host = "admin", access = "admin",
}
local rememberTab = true
local quickKey = ""                  -- revision 2: optional key that opens / closes the menu

local kbBind = "jump"              -- flight input on keyboard / mouse
local padBind = "jump"             -- flight input on a controller
local boostKb = "q"                -- boost input on keyboard / mouse
local boostPad = "interact"        -- boost input on a controller
local capturing = false
local captureTarget = "fly"
local captureStart = 0
local bindTimer = BIND_RESEND
local wasUsingPad = false

local localFuel = nil              -- our own prediction, corrected by the server
local lastFuelOn = false

local gaugeAutoHide = true
local gaugeAlpha = 1
local groundTime = 0
local gaugeSize = 2                -- 1 small, 2 medium, 3 large
local gaugePos = 1                 -- 1 bottom, 2 top, 3 left, 4 right
local gaugeCb = false              -- colourblind-friendly colours

local speedHud = false              -- show our speed on screen
local speedShown = 0
local speedUnit = 1                -- 28.1: 1 m/s, 2 km/h, 3 mph
local altHud = false               -- 28.1: show height above the ground we last stood on
local altShown, altGroundY = 0, nil
local SPEED_FACTOR = { 1, 3.6, 2.23694 }
local SPEED_UNIT_KEYS = { "unit_ms", "unit_kmh", "unit_mph" }

local fxMode = 2                   -- 0 off, 1 flames, 2 flames + smoke + glow

local toastText, toastUntil = "", 0
local noteText, noteUntil = "", 0     -- message from the host, shown to everyone
local lastNoteSeq = nil
local localBoostCd, wasBoosting = 0, false
local playerPage = 1               -- page of the players list
local armedId, armedUntil = nil, 0   -- button waiting for a second click

-- A clicked value shows up right away instead of waiting for the server.
local pending = {}

local function setPending(key, value)
	pending[key] = { value = value, expires = GetTime() + 0.6 }
end

local function pendingValue(key, actual)
	local p = pending[key]
	if p and GetTime() < p.expires then return p.value end
	return actual
end

local function usingPad()
	local ok, device = pcall(LastInputDevice)    -- 0 none, 1 mouse, 2 gamepad
	return ok and device == 2
end

local function activeBind()
	return usingPad() and padBind or kbBind
end

local function activeBoost()
	return usingPad() and boostPad or boostKb
end

local function sendBind()
	bindTimer = 0
	ServerCall("server.setPlayerBind", GetLocalPlayer(), activeBind(), activeBoost())
end

local function setKbBind(bind)
	kbBind = bind
	SetString("savegame.mod.flykey", bind)
	sendBind()
end

local function setPadBind(bind)
	padBind = bind
	SetString("savegame.mod.padkey", bind)
	sendBind()
end

local function setBoostKb(bind)
	boostKb = bind
	SetString("savegame.mod.boostkey", bind)
	sendBind()
end

local function setBoostPad(bind)
	boostPad = bind
	SetString("savegame.mod.boostpadkey", bind)
	sendBind()
end

local function bindLabel(name)
	if STRINGS["act_" .. name] then return T("act_" .. name) end
	if STRINGS["key_" .. name] then return T("key_" .. name) end
	return string.upper(name)
end

local function cycleList(list, current, step)
	for i = 1, #list do
		if list[i] == current then
			return list[(i - 1 + step) % #list + 1]
		end
	end
	return list[1]
end

local function setGaugeAutoHide(on)
	gaugeAutoHide = on and true or false
	SetInt("savegame.mod.hudautohideoff", gaugeAutoHide and 0 or 1)
end

local function setSpeedHud(on)
	speedHud = on and true or false
	SetInt("savegame.mod.speedhud", speedHud and 1 or 0)
end

local function setSpeedUnit(v)
	speedUnit = SPEED_FACTOR[v] and v or 1
	SetInt("savegame.mod.speed_unit", speedUnit)
end

local function setAltHud(on)
	altHud = on and true or false
	altGroundY = nil
	SetInt("savegame.mod.alt_hud", altHud and 1 or 0)
end

local function setFxMode(mode)
	fxMode = mode % 3
	SetInt("savegame.mod.fxmode", fxMode + 1)
end

local function setGaugeSize(v)
	gaugeSize = v
	SetInt("savegame.mod.gauge_size", v)
end

local function setGaugePos(v)
	gaugePos = v
	SetInt("savegame.mod.gauge_pos", v)
end

local function setGaugeCb(on)
	gaugeCb = on and true or false
	SetInt("savegame.mod.gauge_cb", gaugeCb and 1 or 0)
end

local function setQuickKey(key)
	quickKey = key
	SetString("savegame.mod.menukey", key)
end

local function setRememberTab(on)
	rememberTab = on and true or false
	SetInt("savegame.mod.tab_forget", rememberTab and 0 or 1)
end

local function startCapture(target)
	capturing = true
	captureTarget = target or "fly"
	captureStart = GetTime()
end

-- Listens for the next key while a key button is waiting.
-- The left mouse button is ignored: it's what clicked the button.
local function pollCapture()
	if not capturing or GetTime() - captureStart < 0.2 then return end
	local key = InputLastPressedKey()
	if key == "" or key == "lmb" then return end
	capturing = false
	if key == "esc" then return end
	if VALID_INPUTS[key] then
		if captureTarget == "boost" then
			setBoostKb(key)
		elseif captureTarget == "menu" then
			if key == kbBind or key == boostKb then
				toastText, toastUntil = T("key_in_use"), GetTime() + 3
			else
				setQuickKey(key)
			end
		else
			setKbBind(key)
		end
	end
end

local function openSettings()
	settingsOpen = true
	openedAt = GetTime()
	tab = rememberTab and lastTab or "flight"
	capturing = false
	playerPage = 1
	armedId = nil
end


-- client: permissions, fuel and effects -----------------------------------

local function inAllowedList(pid)
	return listHas(shared.allowed, pid)
end

local function localCanFly()
	if shared.enabled == false then return false end
	if shared.restrict then
		local me = GetLocalPlayer()
		if not IsPlayerHost(me) and not inAllowedList(me) then return false end
	end
	return true
end

local function serverFuelFor(pid)
	local ids, values = shared.fuelIds, shared.fuelVals
	if not ids or not values then return nil end
	for i = 1, #ids do
		if ids[i] == pid then return values[i] end
	end
	return nil
end

local function jitter(amount)
	return GetRandomFloat(-amount, amount)
end

-- Flames (and, on full, smoke and a little light) behind a flying player.
local function spawnExhaust(player, mode, boosted)
	local t = GetPlayerTransform(player)
	local origin = TransformToParentPoint(t, Vec(0, 0.85, 0.3))
	local carry = VecScale(GetPlayerVelocity(player), 0.5)

	for i = 1, boosted and 5 or 2 do
		ParticleReset()
		ParticleType("plain")
		ParticleTile(5)
		if boosted then
			ParticleColor(1.0, 0.95, 0.6, 1.0, 0.35, 0.1)
			ParticleRadius(0.13, 0.03, "easeout")
		else
			ParticleColor(1.0, 0.75, 0.3, 1.0, 0.25, 0.1)
			ParticleRadius(0.07, 0.02, "easeout")
		end
		ParticleAlpha(1.0, 0.0, "easeout", 0, 0.4)
		ParticleEmissive(6, 0, "easeout")
		ParticleGravity(0)
		ParticleDrag(0.2)
		ParticleCollide(0)
		SpawnParticle(origin, VecAdd(carry, Vec(jitter(0.4), (boosted and -6 or -3.5) + jitter(0.5), jitter(0.4))), 0.3)
	end

	if mode < 2 then return end

	ParticleReset()
	ParticleType("smoke")
	ParticleColor(0.75, 0.75, 0.75, 0.5, 0.5, 0.5)
	ParticleRadius(0.12, 0.4, "easeout")
	ParticleAlpha(0.35, 0.0, "easeout", 0.1, 0.6)
	ParticleGravity(0.3)
	ParticleDrag(0.4)
	SpawnParticle(origin, VecAdd(carry, Vec(jitter(0.3), -1.8, jitter(0.3))), 1.2)

	PointLight(VecAdd(origin, Vec(0, -0.4, 0)), 1, 0.55, 0.2, boosted and 5 or 2.5)
end

function client.init()
	snd = LoadLoop("jetpack.ogg")

	local savedKb = normalizeBind(GetString("savegame.mod.flykey"))
	if savedKb then kbBind = savedKb end

	local savedPad = GetString("savegame.mod.padkey")
	if PAD_VALID[savedPad] then padBind = savedPad end

	local savedBoost = normalizeBind(GetString("savegame.mod.boostkey"))
	if savedBoost then boostKb = savedBoost end

	local savedBoostPad = GetString("savegame.mod.boostpadkey")
	if PAD_VALID[savedBoostPad] then boostPad = savedBoostPad end

	gaugeAutoHide = GetInt("savegame.mod.hudautohideoff") ~= 1
	speedHud = GetInt("savegame.mod.speedhud") == 1
	local savedUnit = GetInt("savegame.mod.speed_unit")
	if SPEED_FACTOR[savedUnit] then speedUnit = savedUnit end
	altHud = GetInt("savegame.mod.alt_hud") == 1

	local savedMenuKey = normalizeBind(GetString("savegame.mod.menukey"))
	if savedMenuKey then quickKey = savedMenuKey end
	rememberTab = GetInt("savegame.mod.tab_forget") ~= 1
	local savedTab = GetString("savegame.mod.last_tab")
	if savedTab ~= "" then lastTab = LEGACY_TABS[savedTab] or savedTab end

	local savedFx = GetInt("savegame.mod.fxmode")
	if savedFx >= 1 and savedFx <= 3 then fxMode = savedFx - 1 end

	local savedSize = GetInt("savegame.mod.gauge_size")
	if savedSize >= 1 and savedSize <= 3 then gaugeSize = savedSize end
	local savedPos = GetInt("savegame.mod.gauge_pos")
	if savedPos >= 1 and savedPos <= 4 then gaugePos = savedPos end
	gaugeCb = GetInt("savegame.mod.gauge_cb") == 1
end

function client.tick(dt)
	local me = GetLocalPlayer()

	-- Re-send the flight input now and then, and whenever the device changes.
	-- The first message can arrive before the server is ready.
	bindTimer = bindTimer + dt
	local pad = usingPad()
	if bindTimer >= BIND_RESEND or pad ~= wasUsingPad then
		wasUsingPad = pad
		sendBind()
	end

	-- The host can hide the menu from everyone else.
	local menuAllowed = IsPlayerHost(me) or shared.menuHidden ~= true
	if menuAllowed then
		if PauseMenuButton(T("title")) then openSettings() end
		if quickKey ~= "" and not capturing and InputPressed(quickKey) then
			if settingsOpen then settingsOpen = false else openSettings() end
		end
	elseif settingsOpen then
		settingsOpen = false
	end
	pollCapture()

	-- Message from the host (profile applied, mode changed...). The first value
	-- we see belongs to the past, so it isn't shown.
	local seq = shared.noteSeq
	if seq ~= nil then
		if lastNoteSeq ~= nil and seq ~= lastNoteSeq then
			noteText = tostring(shared.noteText or "")
			noteUntil = GetTime() + 4.5
		end
		lastNoteSeq = seq
	end

	local health = GetPlayerHealth(me)
	local inVehicle = GetPlayerVehicle(me) ~= 0
	local tank = shared.fuelCap or FUEL_DEFAULT
	local fuelOn = shared.fuelEnabled == true and not (shared.hostFree == true and IsPlayerHost(me))

	if fuelOn ~= lastFuelOn then
		lastFuelOn = fuelOn
		localFuel = tank
	end
	if localFuel == nil or health <= 0 or localFuel > tank then localFuel = tank end

	if speedHud then
		local ok, vel = pcall(GetPlayerVelocity, me)
		if ok and vel then speedShown = speedShown + (VecLength(vel) - speedShown) * math.min(1, dt * 10) end
	end

	if altHud then
		local ok, t = pcall(GetPlayerTransform, me)
		if ok and t then
			local y = t.pos[2]
			if altGroundY == nil or health <= 0 or inVehicle or isGrounded(me) then altGroundY = y end
			altShown = altShown + (math.max(0, y - altGroundY) - altShown) * math.min(1, dt * 10)
		end
	end

	local boostingList = shared.boosting
	local meBoosting = listHas(boostingList, me)
	if meBoosting and not wasBoosting then localBoostCd = shared.boostCd or BOOST_CD_DEFAULT end
	wasBoosting = meBoosting
	localBoostCd = math.max(0, localBoostCd - dt)

	local wantsToFly = localCanFly() and health > 0 and not inVehicle and inputHeld(activeBind())
	local flying = wantsToFly and (not fuelOn or localFuel > 0.02)

	if fuelOn then
		local grounded = inVehicle or isGrounded(me)
		local endurance, refillMul = fuelMultipliers(me)

		if flying then
			localFuel = math.max(0, localFuel - dt / endurance)
		elseif grounded and groundTime >= (shared.refillDelay or DELAY_DEFAULT) then
			localFuel = math.min(tank, localFuel + dt * tank / (shared.refill or REFILL_DEFAULT) * refillMul)
		end

		-- close enough is fine, but snap back if we've drifted
		local serverValue = serverFuelFor(me)
		if serverValue and math.abs(serverValue - localFuel) > FUEL_SNAP_DISTANCE then
			localFuel = serverValue
		end

		if grounded and not flying then
			groundTime = groundTime + dt
		else
			groundTime = 0
		end
		local target = (gaugeAutoHide and groundTime > GAUGE_HIDE_DELAY) and 0 or 1
		gaugeAlpha = gaugeAlpha + (target - gaugeAlpha) * math.min(1, dt * GAUGE_FADE_RATE)
	else
		groundTime = 0
		gaugeAlpha = 1
	end

	if flying then
		PlayLoop(snd, GetCameraTransform().pos, SOUND_VOLUME)
		if fxMode > 0 then pcall(spawnExhaust, me, fxMode, meBoosting) end
	end

	local others = shared.jetting
	if others then
		for i = 1, #others do
			local p = others[i]
			if p ~= me and IsPlayerValid(p) then
				PlayLoop(snd, GetPlayerTransform(p).pos, SOUND_VOLUME)
				if fxMode > 0 then pcall(spawnExhaust, p, fxMode, listHas(boostingList, p)) end
			end
		end
	end
end


-- client: ui toolkit ------------------------------------------------------
-- Every widget is placed by its centre, relative to the current origin.
--
-- The window is split into fixed zones so nothing can overlap:
--   header   y -300 .. -196   title, subtitle, version badge
--   body     y -180 ..  204   sidebar on the left, tab content on the right
--   footer   y  216 ..  300   version / hint text and the Close button
-- Tab content is laid out from the top of the body downwards (y = 0 is the
-- top of the body, the body is BODY_H tall). Cards never touch each other.
--
-- With a controller we run our own focus: widgets register themselves in
-- nav.items while drawing and the focused one gets a ring.

local ACCENT = { 1.0, 0.82, 0.18 }
local ACCENT_PALETTE = {
	{ "Amber", 1.0, 0.82, 0.18 }, { "Sky", 0.35, 0.70, 0.95 }, { "Green", 0.45, 0.85, 0.55 },
	{ "Pink", 0.95, 0.50, 0.75 }, { "Orange", 1.0, 0.55, 0.20 },
}
local accentIndex, accentLoaded = 1, false

-- ACCENT is changed in place, so everything that uses it follows.
local function setAccent(i, save)
	i = ACCENT_PALETTE[i] and i or 1
	accentIndex = i
	ACCENT[1], ACCENT[2], ACCENT[3] = ACCENT_PALETTE[i][2], ACCENT_PALETTE[i][3], ACCENT_PALETTE[i][4]
	if save then SetInt("savegame.mod.accent", i) end
end
local PANEL  = { 0.07, 0.07, 0.08 }
local BTN    = { 0.20, 0.20, 0.22 }
local GREEN  = { 0.25, 0.65, 0.35 }
local RED    = { 0.70, 0.27, 0.27 }
local WHITE  = { 1, 1, 1 }
local DARK   = { 0.08, 0.08, 0.08 }
local GOOD   = { 0.45, 0.85, 0.55 }
local BAD    = { 0.90, 0.45, 0.45 }

local PANEL_W, PANEL_H = 880, 600
local BODY_TOP, BODY_H = -180, 384
local SIDEBAR_X, SIDEBAR_W = -330, 180
local CONTENT_X, CW = 100, 630          -- content centre and width
local PAD = 20
local LEFT, RIGHT = -CW / 2 + PAD, CW / 2 - PAD
local ROW_H, ROW_GAP = 48, 6

local nav = { items = {}, focus = 1, active = false, accept = false, offset = 0, offsetY = 0 }
local pressHandled = false

local function label(text, x, y, size, color, alpha, align, maxWidth)
	UiPush()
		UiTranslate(x, y)
		UiAlign(align or "center middle")
		UiFont("regular.ttf", size)
		if maxWidth then
			local width = UiGetTextSize(text)
			if width > maxWidth then
				size = math.max(11, math.floor(size * maxWidth / width))
				UiFont("regular.ttf", size)
			end
		end
		UiColor(color[1], color[2], color[3], alpha or 1)
		UiText(text)
	UiPop()
end

local function isHover(x, y, w, h)
	if nav.active then return false end
	local inside = false
	UiPush()
		UiTranslate(x - w / 2, y - h / 2)
		UiAlign("left top")
		inside = UiIsMouseInRect(w, h)
	UiPop()
	return inside
end

local function ring(w, h)
	local t = 3
	UiPush()
		UiAlign("center middle")
		UiColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
		UiPush() UiTranslate(0, -h / 2) UiRect(w, t) UiPop()
		UiPush() UiTranslate(0, h / 2) UiRect(w, t) UiPop()
		UiPush() UiTranslate(-w / 2, 0) UiRect(t, h) UiPop()
		UiPush() UiTranslate(w / 2, 0) UiRect(t, h) UiPop()
	UiPop()
end

-- Invisible click area. We react when the mouse is pressed so one click is
-- enough; the normal button release is only a fallback.
local function hit(x, y, w, h)
	local id = #nav.items + 1
	nav.items[id] = { x = nav.offset + x, y = nav.offsetY + y }

	if nav.active then
		if id ~= nav.focus then return false end
		UiPush()
			UiTranslate(x, y)
			ring(w + 8, h + 8)
		UiPop()
		return nav.accept
	end

	local hover = isHover(x, y, w, h)
	local clicked = false
	UiPush()
		UiTranslate(x, y)
		UiAlign("center middle")
		UiColor(0, 0, 0, 0)
		local released = UiTextButton(" ", w, h)
		if hover and InputPressed("lmb") then
			clicked = true
			pressHandled = true
		elseif released then
			if pressHandled then pressHandled = false else clicked = true end
		end
	UiPop()
	return clicked
end

local function lighten(color, k)
	return math.min(color[1] * k, 1), math.min(color[2] * k, 1), math.min(color[3] * k, 1)
end

local function card(x, y, w, h, alpha)
	UiPush()
		UiTranslate(x, y)
		UiAlign("center middle")
		UiColor(1, 1, 1, alpha or 0.055)
		UiRoundedRect(w, h, 12)
	UiPop()
end

local function button(text, x, y, w, h, bg, fg, size, disabled)
	local hover = (not disabled) and isHover(x, y, w, h)
	local r, g, b = lighten(bg, hover and 1.3 or 1.0)
	local a = disabled and 0.4 or 1
	UiPush()
		UiTranslate(x, y)
		UiAlign("center middle")
		UiColor(r, g, b, a)
		UiRoundedRect(w, h, 8)
	UiPop()
	label(text, x, y, size or 22, fg, a, "center middle", w - 14)
	local clicked = hit(x, y, w, h)
	return clicked and not disabled
end

local function switch(x, y, on)
	local w, h = 60, 30
	local r, g, b = lighten(on and GREEN or { 0.32, 0.32, 0.35 }, isHover(x, y, w, h) and 1.2 or 1.0)
	UiPush()
		UiTranslate(x, y)
		UiAlign("center middle")
		UiColor(r, g, b, 1)
		UiRoundedRect(w, h, h / 2)
		UiTranslate(on and 15 or -15, 0)
		UiColor(1, 1, 1, 1)
		UiRoundedRect(22, 22, 11)
	UiPop()
	return hit(x, y, w, h)
end

-- Focus moves to the nearest widget in the pressed direction.
local function moveFocus(dx, dy)
	local current = nav.items[nav.focus]
	if not current then nav.focus = 1 return end

	local best, bestScore
	for i, item in ipairs(nav.items) do
		if i ~= nav.focus then
			local ox, oy = item.x - current.x, item.y - current.y
			local along = dx * ox + dy * oy
			local across = math.abs(dx * oy - dy * ox)
			if along > 4 then
				local score = along + across * 2
				if not bestScore or score < bestScore then
					best, bestScore = i, score
				end
			end
		end
	end
	if best then nav.focus = best end
end

local function handleControllerInput(tabs)
	if not nav.active then return end

	nav.focus = math.max(1, math.min(nav.focus, #nav.items))

	if InputPressed("menu_up") then moveFocus(0, -1) end
	if InputPressed("menu_down") then moveFocus(0, 1) end
	if InputPressed("menu_left") then moveFocus(-1, 0) end
	if InputPressed("menu_right") then moveFocus(1, 0) end

	local step = 0
	if InputPressed("menu_next") then step = 1 end
	if InputPressed("menu_prev") then step = -1 end
	if step ~= 0 then
		for i = 1, #tabs do
			if tabs[i].id == tab then
				tab = tabs[(i - 1 + step) % #tabs + 1].id
				break
			end
		end
	end

	if InputPressed("menu_cancel") then settingsOpen = false end
end



-- client: HUD -------------------------------------------------------------

local GAUGE_SCALE = { 0.8, 1.0, 1.35 }

-- centre of the gauge, its scale, and whether the readouts hang below it
local function gaugeAnchor()
	local s = GAUGE_SCALE[gaugeSize] or 1
	local w, h = UiWidth(), UiHeight()
	local half = 103 * s
	if gaugePos == 2 then return w / 2, 72, s, true end
	if gaugePos == 3 then return 24 + half, h - 72, s, false end
	if gaugePos == 4 then return w - 24 - half, h - 72, s, false end
	return w / 2, h - 72, s, false
end

-- default: amber / red. Colourblind: blue / vermillion (Okabe-Ito), also easy to tell apart by lightness.
local function gaugeColors()
	if gaugeCb then return { 0.34, 0.71, 0.91 }, { 0.84, 0.37, 0.0 } end
	return ACCENT, { 0.95, 0.28, 0.24 }
end

local function drawGauge()
	local me = GetLocalPlayer()
	if gaugeAlpha < 0.02 then return end
	if not localCanFly() or GetPlayerHealth(me) <= 0 or GetPlayerVehicle(me) ~= 0 then return end
	if shared.hostFree == true and IsPlayerHost(me) then return end

	local tank = shared.fuelCap or FUEL_DEFAULT
	local current = localFuel or tank
	local fraction = math.max(0, math.min(1, current / tank))
	local a = gaugeAlpha
	local low = fraction > 0.02 and fraction <= 0.22
	local pulse = low and (0.7 + 0.3 * math.sin(GetTime() * 9)) or 1     -- low fuel warning
	local normal, lowColor = gaugeColors()
	local ax, ay, s, top = gaugeAnchor()

	UiPush()
		UiTranslate(ax, ay)
		UiScale(s)
		UiAlign("center middle")

		UiColor(0.04, 0.04, 0.05, 0.75 * a)
		UiRoundedRect(206, 16, 8)
		UiColor(1, 1, 1, 0.10 * a)
		UiRoundedRect(200, 10, 5)

		if fraction > 0 then
			UiPush()
				UiTranslate(-98, 0)
				UiAlign("left middle")
				local c = (fraction > 0.22) and normal or lowColor
				UiColor(c[1], c[2], c[3], 0.95 * a * pulse)
				UiRoundedRect(math.max(196 * fraction, 6), 8, 4)
			UiPop()
		end

		local ly = top and 17 or -17
		if fraction <= 0.02 then
			label(T("hud_empty"), 0, ly, 15, lowColor, a)
		else
			label(T("hud_fuel", current), 0, ly, 15, WHITE, 0.82 * a)
		end
	UiPop()
end

local function drawSpeed()
	local me = GetLocalPlayer()
	if not localCanFly() or GetPlayerHealth(me) <= 0 or GetPlayerVehicle(me) ~= 0 then return end
	local ax, ay, s, top = gaugeAnchor()
	local lines = {}
	if speedHud then
		lines[#lines + 1] = string.format("%d %s", math.floor(speedShown * SPEED_FACTOR[speedUnit] + 0.5),
			T(SPEED_UNIT_KEYS[speedUnit]))
	end
	if altHud then lines[#lines + 1] = T("alt_value", math.floor(altShown + 0.5)) end
	for i = 1, #lines do
		label(lines[i], ax, ay + (top and 1 or -1) * (40 + (i - 1) * 24) * s, math.floor(20 * s), WHITE, 0.8)
	end
end

-- Small cooldown bar for the boost, on the other side of the gauge from the readouts.
local function drawBoost()
	local me = GetLocalPlayer()
	if shared.boostOn ~= true or not localCanFly() then return end
	if GetPlayerHealth(me) <= 0 or GetPlayerVehicle(me) ~= 0 then return end

	local ax, ay, s, top = gaugeAnchor()
	local dir = top and -1 or 1
	local y = ay + dir * 24 * s
	local total = math.max(1, shared.boostCd or BOOST_CD_DEFAULT)
	local ready = localBoostCd <= 0
	local frac = ready and 1 or (1 - localBoostCd / total)
	local c = ready and (gaugeCb and { 0.34, 0.71, 0.91 } or GOOD) or { 0.6, 0.6, 0.65 }

	UiPush()
		UiTranslate(ax - 50 * s, y)
		UiAlign("left middle")
		UiColor(1, 1, 1, 0.12)
		UiRoundedRect(100 * s, 5 * s, 2.5 * s)
		UiColor(c[1], c[2], c[3], 0.9)
		UiRoundedRect(math.max(100 * s * frac, 5 * s), 5 * s, 2.5 * s)
	UiPop()
	label(ready and T("boost_ready") or T("boost_wait", math.ceil(localBoostCd)),
		ax, y + dir * 11 * s, math.floor(12 * s), c, ready and 0.9 or 0.65)
end

-- Short message from the host, top centre, for every player.
local function drawNote()
	local now = GetTime()
	if now >= noteUntil or noteText == "" then return end
	local a = math.min(1, (noteUntil - now) / 0.6)
	local w = 0
	UiPush()
		UiFont("regular.ttf", 20)
		w = UiGetTextSize(noteText)
	UiPop()
	w = math.min(w, UiWidth() - 120)
	UiPush()
		UiTranslate(UiCenter(), 64)
		UiAlign("center middle")
		UiColor(0.04, 0.04, 0.05, 0.85 * a)
		UiRoundedRect(w + 64, 46, 23)
		UiPush()
			UiTranslate(-(w + 64) / 2 + 24, 0)
			UiColor(ACCENT[1], ACCENT[2], ACCENT[3], a)
			UiRoundedRect(10, 10, 5)
		UiPop()
		label(noteText, 10, 0, 20, WHITE, a, "center middle", UiWidth() - 140)
	UiPop()
end


-- client: settings tabs ---------------------------------------------------
-- Seven tabs at most:  Game: Flight, Fuel & Boost   Host: Players, Admin
--                      You: Controls, HUD, Stats
-- Everything the host can change sits under Game or Host. Players see the
-- same Game tabs read-only. Drawn with the origin at the middle-top of the
-- content area (y = 0 is the top of the body).

local MODE_KEYS = { "mode_classic", "mode_hover", "mode_glide" }
local MODE_DESC = { "mode_classic_d", "mode_hover_d", "mode_glide_d" }

-- Every tab is a column of up to seven rows, ROW_H high with ROW_GAP between.
-- `top` is the top edge inside the body; the row functions return its centre.
local function settingRow(top, title, subtitle, maxWidth, alpha)
	local cy = top + ROW_H / 2
	alpha = alpha or 1
	card(0, cy, CW, ROW_H)
	if subtitle == nil or subtitle == "" then
		label(title, LEFT, cy, 21, WHITE, alpha, "left middle", maxWidth)
	else
		label(title, LEFT, cy - 9, 21, WHITE, alpha, "left middle", maxWidth)
		label(subtitle, LEFT, cy + 12, 14, WHITE, 0.5 * alpha, "left middle", maxWidth)
	end
	return cy
end

local function onOffText(x, y, on)
	label(on and T("on") or T("off"), x, y, 21, on and GOOD or BAD, 1, "right middle")
end

-- Row with an on/off switch. Players who can't edit just see On / Off.
local function toggleRow(top, title, subtitle, on, canEdit, onToggle, alpha)
	local cy = settingRow(top, title, subtitle, canEdit and 500 or 440, alpha)
	if canEdit then
		if switch(RIGHT - 30, cy, on) then onToggle() end
	else
		onOffText(RIGHT, cy, on)
	end
	return cy
end

-- Row with  [-]  value  [+]  on the right.
local function stepRow(top, title, subtitle, valueText, canEdit, onMinus, onPlus, alpha)
	alpha = alpha or 1
	local cy = settingRow(top, title, subtitle, canEdit and 380 or 400, alpha)
	if canEdit then
		if button("-", RIGHT - 185, cy, 44, 34, BTN, WHITE, 24) then onMinus() end
		label(valueText, RIGHT - 110, cy, 22, ACCENT, alpha, "center middle", 90)
		if button("+", RIGHT - 35, cy, 44, 34, BTN, WHITE, 24) then onPlus() end
	else
		label(valueText, RIGHT, cy, 22, ACCENT, alpha, "right middle", 140)
	end
	return cy
end

-- Row with a few choice buttons on the right. `current` is the chosen index.
local function choiceRow(top, title, subtitle, options, current, canEdit, onPick, alpha)
	local n = #options
	local w = (n == 2) and 120 or ((n == 3) and 104 or 80)
	local cy = settingRow(top, title, subtitle, CW - PAD * 2 - n * (w + 6) - 10, alpha)
	for i = 1, n do
		local x = RIGHT - w / 2 - (n - i) * (w + 6)
		local active = (current == i)
		if button(T(options[i]), x, cy, w, 34, active and ACCENT or BTN, active and DARK or WHITE, 17, not canEdit) then
			onPick(i)
		end
	end
	return cy
end

-- Small  [-] value [+]  used when two settings share a row.
local function miniStepper(x, y, text, color, alpha, canEdit, onMinus, onPlus)
	if canEdit and button("-", x - 45, y, 34, 32, BTN, WHITE, 22) then onMinus() end
	label(text, x, y, 20, color, alpha, "center middle", 56)
	if canEdit and button("+", x + 45, y, 34, 32, BTN, WHITE, 22) then onPlus() end
end

-- A button that needs a second click within three seconds.
local function armedButton(id, text, x, y, w, h, onConfirm)
	local armed = (armedId == id) and GetTime() < armedUntil
	if button(armed and T("confirm_short") or text, x, y, w, h, armed and RED or BTN, WHITE, 16) then
		if armed then
			armedId = nil
			onConfirm()
		else
			armedId, armedUntil = id, GetTime() + 3
		end
	end
end

local function rowTop(n)
	return (n - 1) * (ROW_H + ROW_GAP)
end

-- Short message under the title (the header shows it for three seconds).
local function toast(text)
	toastText, toastUntil = text, GetTime() + 3
end

-- Show a clicked value straight away and send it to the server.
local function setValue(key, value, call)
	setPending(key, value)
	ServerCall(call, value)
end

local function flip(key, current, call)
	setValue(key, not current, call)
end



local function tabFlight(c)
	local h = c.isHost
	local a = c.enabled and 1 or 0.5
	local lo, hi, step = thrustLimits()

	toggleRow(rowTop(1), T("jetpack"), T("jetpack_sub"), c.enabled, h, function()
		flip("enabled", c.enabled, "server.setEnabled")
	end)

	choiceRow(rowTop(2), T("mode_title"), T(MODE_DESC[c.mode] or MODE_DESC[1]), MODE_KEYS, c.mode, h, function(i)
		setValue("mode", i, "server.setMode")
	end, a)

	local function setThrust(v) setValue("thrust", clampThrust(v), "server.setThrustPct") end
	stepRow(rowTop(3), T("thrust"), T("thrust_sub", lo, hi), c.thrust .. "%", h,
		function() setThrust(c.thrust - step) end,
		function() setThrust(c.thrust + step) end, a)

	-- minus from "no limit" goes to the maximum, plus from the maximum goes to "no limit"
	local function setCap(v) setValue("cap", clampCap(v), "server.setSpeedCap") end
	stepRow(rowTop(4), T("speed_cap"), T("speed_cap_sub"),
		c.cap == 0 and T("speed_off") or T("speed_value", c.cap), h,
		function()
			if c.cap == 0 then setCap(CAP_MAX) else setCap(math.max(CAP_MIN, c.cap - CAP_STEP)) end
		end,
		function()
			if c.cap == 0 then return end
			if c.cap + CAP_STEP > CAP_MAX then setCap(0) else setCap(c.cap + CAP_STEP) end
		end, a)

	local function setCeiling(v) setValue("ceiling", clampCeiling(v), "server.setCeiling") end
	stepRow(rowTop(5), T("ceiling"), T("ceiling_sub"),
		c.ceiling == 0 and T("speed_off") or string.format("%d m", c.ceiling), h,
		function()
			if c.ceiling == 0 then setCeiling(CEIL_MAX) else setCeiling(math.max(CEIL_MIN, c.ceiling - CEIL_STEP)) end
		end,
		function()
			if c.ceiling == 0 then return end
			if c.ceiling + CEIL_STEP > CEIL_MAX then setCeiling(0) else setCeiling(c.ceiling + CEIL_STEP) end
		end, a)

	toggleRow(rowTop(6), T("smooth"), T("smooth_sub"), c.smooth, h, function()
		flip("smooth", c.smooth, "server.setSmooth")
	end, a)

	toggleRow(rowTop(7), T("hover_assist"), T("hover_assist_sub"), c.hover, h, function()
		flip("hover", c.hover, "server.setHover")
	end, a)
end

local function tabFuel(c)
	local h = c.isHost
	local fa = c.fuelOn and 1 or 0.5
	local ba = c.boostOn and 1 or 0.5

	toggleRow(rowTop(1), T("fuel_system"), T("fuel_sub"), c.fuelOn, h, function()
		flip("fuelOn", c.fuelOn, "server.setFuelEnabled")
	end)

	local function setTank(v) setValue("tank", clampFuel(v), "server.setFuelCap") end
	stepRow(rowTop(2), T("tank"), T("tank_sub", FUEL_MIN, FUEL_MAX), c.tank .. " s", h,
		function() setTank(c.tank - 1) end, function() setTank(c.tank + 1) end, fa)

	local function setRefill(v) setValue("refill", clampRefill(v), "server.setRefill") end
	stepRow(rowTop(3), T("refill_time"), T("refill_time_sub"), string.format("%.1f s", c.refill), h,
		function() setRefill(c.refill - REFILL_STEP) end,
		function() setRefill(c.refill + REFILL_STEP) end, fa)

	local function setDelay(v) setValue("delay", clampDelay(v), "server.setRefillDelay") end
	stepRow(rowTop(4), T("refill_delay"), T("refill_delay_sub"), string.format("%.1f s", c.refillDelay), h,
		function() setDelay(c.refillDelay - DELAY_STEP) end,
		function() setDelay(c.refillDelay + DELAY_STEP) end, fa)

	toggleRow(rowTop(5), T("boost"), T("boost_sub"), c.boostOn, h, function()
		flip("boostOn", c.boostOn, "server.setBoostOn")
	end)

	-- boost tuning shares one row
	local cy = rowTop(6) + ROW_H / 2
	card(0, cy, CW, ROW_H)
	label(T("boost_cd"), LEFT, cy, 18, WHITE, 0.8 * ba, "left middle", 80)
	miniStepper(-110, cy, string.format("%d s", c.boostCd), ACCENT, ba, h,
		function() setValue("boostCd", clampBoostCd(c.boostCd - 1), "server.setBoostCd") end,
		function() setValue("boostCd", clampBoostCd(c.boostCd + 1), "server.setBoostCd") end)
	label(T("boost_cost"), -10, cy, 18, WHITE, 0.8 * ba, "left middle", 100)
	miniStepper(190, cy, string.format("%.1f s", c.boostCost), ACCENT, ba, h,
		function() setValue("boostCost", clampBoostCost(c.boostCost - BOOST_COST_STEP), "server.setBoostCost") end,
		function() setValue("boostCost", clampBoostCost(c.boostCost + BOOST_COST_STEP), "server.setBoostCost") end)

	toggleRow(rowTop(7), T("upgrades"), T("upgrades_sub"), c.upgrades, h, function()
		flip("upgrades", c.upgrades, "server.setUpgrades")
	end)
end

local STAT_COLORS = { { 1.0, 0.82, 0.18 }, { 0.35, 0.70, 0.95 }, { 0.45, 0.85, 0.55 } }

local function statCard(x, y, w, h, color, title, value, sub)
	card(x, y, w, h)
	UiPush()
		UiTranslate(x, y - h / 2 + 5)
		UiAlign("center middle")
		UiColor(color[1], color[2], color[3], 0.9)
		UiRoundedRect(w - 28, 4, 2)
	UiPop()
	label(title, x, y - 26, 14, WHITE, 0.55, "center middle", w - 20)
	label(value, x, y + 4, 36, color, 1, "center middle", w - 24)
	label(sub, x, y + 32, 14, WHITE, 0.4, "center middle", w - 20)
end

local function tabStats(c)
	local me = GetLocalPlayer()
	local peak, dist, time, boosts = getStats(me)

	statCard(-215, 48, 200, 96, STAT_COLORS[1], T("stat_peak"), fmtDist(peak), T("stat_peak_sub"))
	statCard(0, 48, 200, 96, STAT_COLORS[2], T("stat_dist"), fmtDist(dist), T("stat_dist_sub"))
	statCard(215, 48, 200, 96, STAT_COLORS[3], T("stat_time"), fmtTime(time), T("stat_boosts", boosts))

	-- upgrade progress
	local a = c.upgrades and 1 or 0.4
	card(0, 167, CW, 118)
	label(T("up_title"), LEFT, 124, 20, WHITE, 1, "left middle", 200)
	if not c.upgrades then
		label(T("up_off"), RIGHT, 124, 14, WHITE, 0.5, "right middle", 340)
	end
	for i, up in ipairs(UPGRADES) do
		local y = 152 + (i - 1) * 28
		local tier = upTier(up, time)
		label(up.name, LEFT, y, 17, WHITE, a, "left middle", 70)
		for t = 1, #up.at do
			UiPush()
				UiTranslate(-215 + (t - 1) * 18, y)
				UiAlign("center middle")
				if t <= tier then
					UiColor(ACCENT[1], ACCENT[2], ACCENT[3], a)
				else
					UiColor(1, 1, 1, 0.15)
				end
				UiRoundedRect(12, 12, 6)
			UiPop()
		end
		local frac = 1
		if tier < #up.at then
			local lo = tier > 0 and up.at[tier] or 0
			frac = (time - lo) / (up.at[tier + 1] - lo)
		end
		UiPush()
			UiTranslate(-160, y)
			UiAlign("left middle")
			UiColor(1, 1, 1, 0.12)
			UiRoundedRect(250, 6, 3)
			UiColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.9 * a)
			UiRoundedRect(math.max(6, 250 * math.max(0, math.min(1, frac))), 6, 3)
		UiPop()
		local text = tier > 0 and T("up_tier", tier, math.floor(up.bonus[tier] * 100 + 0.5)) or T("up_locked")
		if tier >= #up.at then text = text .. "   " .. T("up_max") end
		label(text, RIGHT, y, 15, tier > 0 and ACCENT or WHITE, tier > 0 and a or 0.5 * a, "right middle", 190)
	end

	-- pilots
	local rows = {}
	for _, p in ipairs(GetAllPlayers()) do
		local pk, ds, tm = getStats(p)
		rows[#rows + 1] = { p = p, peak = pk, dist = ds, time = tm }
	end
	table.sort(rows, function(x, y)
		if x.dist ~= y.dist then return x.dist > y.dist end
		return x.p < y.p
	end)

	local shown = math.min(4, #rows)
	local maxDist = 1
	for i = 1, shown do maxDist = math.max(maxDist, rows[i].dist) end

	card(0, 311, CW, 146)
	label(#rows > 4 and T("pilots_more", #rows - 4) or T("pilots"), LEFT, 252, 17, WHITE, 0.9, "left middle", 200)
	label(T("col_peak"), 120, 252, 13, WHITE, 0.45, "right middle")
	label(T("col_dist"), 205, 252, 13, WHITE, 0.45, "right middle")
	label(T("col_time"), 285, 252, 13, WHITE, 0.45, "right middle")

	for i = 1, shown do
		local r = rows[i]
		local y = 279 + (i - 1) * 26
		local mine = (r.p == me)
		UiPush()
			UiTranslate(-CW / 2 + 12, y)
			UiAlign("left middle")
			UiColor(ACCENT[1], ACCENT[2], ACCENT[3], mine and 0.22 or 0.10)
			UiRoundedRect(math.max(8, (CW - 24) * r.dist / maxDist), 22, 6)
		UiPop()
		label(i .. ".  " .. tostring(GetPlayerName(r.p)), LEFT, y, 17, mine and ACCENT or WHITE, 0.95, "left middle", 190)
		label(fmtDist(r.peak), 120, y, 16, WHITE, 0.85, "right middle", 70)
		label(fmtDist(r.dist), 205, y, 16, WHITE, 0.85, "right middle", 80)
		label(fmtTime(r.time), 285, y, 16, WHITE, 0.85, "right middle", 70)
	end
end



local function stepMul(p, kind, current, delta, hi)
	local value = clampMul(current + delta, hi)
	setPending((kind == "thrust" and "mt" or "mf") .. p, value)
	ServerCall("server.setPlayerMul", p, kind, value)
end

local function mulColor(v)
	if v ~= 100 then return ACCENT end
	return WHITE
end

-- Host: who may fly, and per-player thrust / endurance.
local function tabPlayers(c)
	toggleRow(rowTop(1), T("approval"), c.restrict and T("approval_on_sub") or T("approval_off_sub"),
		c.restrict, true, function()
			flip("restrict", c.restrict, "server.setRestrict")
		end)

	if button(T("allow_all"), -155, 72, 300, 26, GREEN, WHITE, 16, not c.restrict) then
		ServerCall("server.setAllowedAll", true)
	end
	if button(T("block_all"), 155, 72, 300, 26, RED, WHITE, 16, not c.restrict) then
		ServerCall("server.setAllowedAll", false)
	end

	local players = GetAllPlayers()
	local perPage = 3
	local pages = math.max(1, math.ceil(#players / perPage))
	playerPage = math.max(1, math.min(playerPage, pages))
	local first = (playerPage - 1) * perPage

	for i = 1, perPage do
		local p = players[first + i]
		if not p then break end
		local y = 129 + (i - 1) * 76
		local y1, y2 = y - 18, y + 17

		card(0, y, CW, 70)
		label(tostring(GetPlayerName(p)), LEFT, y1, 20, WHITE, 0.95, "left middle", 160)

		local peak, dist = getStats(p)
		label(T("row_peak", fmtDist(peak)) .. "   -   " .. fmtDist(dist), -120, y1, 15, WHITE, 0.55, "left middle", 200)

		local isHostPlayer = IsPlayerHost(p)
		if isHostPlayer then
			label(T("host"), RIGHT, y1, 19, ACCENT, 0.9, "right middle")
		else
			-- compare with the real value, so the others don't flicker while the server catches up
			local can = pendingValue("fly" .. p, (shared.restrict ~= true) or inAllowedList(p))
			if button(can and T("can_fly") or T("blocked"), RIGHT - 55, y1, 110, 26,
				can and GREEN or RED, WHITE, 16) then
				setPending("fly" .. p, not can)
				if can then setPending("restrict", true) end
				ServerCall("server.setPlayerFlight", p, not can)
			end
		end

		local oT, oF = getOverrides(p)
		oT = pendingValue("mt" .. p, oT)
		oF = pendingValue("mf" .. p, oF)

		label(T("row_thrust"), LEFT, y2, 15, WHITE, 0.5, "left middle", 60)
		if button("-", -228, y2, 28, 26, BTN, WHITE, 20) then stepMul(p, "thrust", oT, -MUL_STEP, MUL_T_MAX) end
		label(oT .. "%", -190, y2, 17, mulColor(oT), 0.9, "center middle", 50)
		if button("+", -152, y2, 28, 26, BTN, WHITE, 20) then stepMul(p, "thrust", oT, MUL_STEP, MUL_T_MAX) end

		label(T("row_fuel"), -122, y2, 15, WHITE, 0.5, "left middle", 74)
		if button("-", -30, y2, 28, 26, BTN, WHITE, 20) then stepMul(p, "fuel", oF, -MUL_STEP, MUL_F_MAX) end
		label(oF .. "%", 10, y2, 17, mulColor(oF), 0.9, "center middle", 50)
		if button("+", 50, y2, 28, 26, BTN, WHITE, 20) then stepMul(p, "fuel", oF, MUL_STEP, MUL_F_MAX) end

		if button(T("reset"), 108, y2, 76, 26, BTN, WHITE, 15, oT == 100 and oF == 100) then
			setPending("mt" .. p, 100)
			setPending("mf" .. p, 100)
			ServerCall("server.resetPlayer", p)
		end

		if c.fuelOn and not (c.hostFree and isHostPlayer) then
			local amount = serverFuelFor(p) or c.tank
			if button(T("refill") .. string.format("  %.1f s", amount), RIGHT - 65, y2, 130, 26, BTN, WHITE, 15) then
				ServerCall("server.refillPlayer", p)
			end
		end
	end

	if pages > 1 then
		if button("<", -60, 358, 44, 26, BTN, WHITE, 18) then
			playerPage = (playerPage - 2) % pages + 1
		end
		label(playerPage .. " / " .. pages, 0, 358, 17, WHITE, 0.7)
		if button(">", 60, 358, 44, 26, BTN, WHITE, 18) then
			playerPage = playerPage % pages + 1
		end
	end
end

local PROFILE_BUTTONS = { "original", "balanced", "turbo", "custom1", "custom2" }
local PROFILE_LABEL = {
	original = "profile_original", balanced = "profile_balanced", turbo = "profile_turbo",
	custom1 = "custom_1", custom2 = "custom_2",
}

-- A profile as the client sees it: built in, or a custom slot published by the server.
local function profileDef(name)
	local slot = tonumber(string.match(name, "^custom(%d)$"))
	if slot then
		local l = shared["custom" .. slot]
		if l and #l == 5 then
			return { thrust = l[1], cap = l[2], smooth = l[3] == 1, fuel = l[4] == 1, tank = l[5] }
		end
		return nil
	end
	return PROFILES[name]
end

local function applyProfileHere(name)
	local p = profileDef(name)
	if not p then return end
	setPending("thrust", p.thrust)
	setPending("cap", p.cap)
	setPending("smooth", p.smooth)
	setPending("fuelOn", p.fuel)
	setPending("tank", p.tank)
	ServerCall("server.applyProfile", name)
end

local function activeProfile(c)
	for _, name in ipairs(PROFILE_BUTTONS) do
		local p = profileDef(name)
		if p and c.thrust == p.thrust and c.cap == p.cap and c.smooth == p.smooth
			and c.fuelOn == p.fuel and (not p.fuel or c.tank == p.tank) then
			return name
		end
	end
	return nil
end

-- Everything back to how the mod ships, on screen straight away.
local function resetHostSettings()
	setPending("enabled", true)
	setPending("menuHidden", false)
	setPending("announce", true)
	setPending("hostFree", false)
	setPending("restrict", false)
	applyProfileHere("original")
	setPending("refill", REFILL_DEFAULT)
	setPending("delay", DELAY_DEFAULT)
	setPending("ceiling", 0)
	setPending("mode", 1)
	setPending("hover", true)
	setPending("boostOn", false)
	setPending("boostCd", BOOST_CD_DEFAULT)
	setPending("boostCost", BOOST_COST_DEFAULT)
	setPending("upgrades", false)
	ServerCall("server.resetAll")
end

-- Host: profiles, session switches and one-click actions.
local function tabAdmin(c)
	card(0, 66, CW, 132)
	label(T("profiles"), LEFT, 20, 21, WHITE, 1, "left middle", 300)
	label(T("profiles_sub"), LEFT, 41, 14, WHITE, 0.5, "left middle", CW - 40)

	local current = activeProfile(c)
	for i, name in ipairs(PROFILE_BUTTONS) do
		local active = (current == name)
		local empty = (profileDef(name) == nil)
		if button(T(PROFILE_LABEL[name]), (i - 3) * 120, 78, 112, 34,
			active and ACCENT or BTN, active and DARK or WHITE, 17, empty) then
			applyProfileHere(name)
			toast(T("toast_applied", T(PROFILE_LABEL[name])))
		end
	end

	label(T("save_to"), LEFT, 111, 15, WHITE, 0.55, "left middle", 170)
	for slot = 1, 2 do
		if button(T("custom_" .. slot), -70 + (slot - 1) * 130, 111, 120, 26, GREEN, WHITE, 16) then
			ServerCall("server.saveCustom", slot)
			toast(T("toast_saved", T("custom_" .. slot)))
		end
	end

	toggleRow(138, T("host_free"), T("host_free_sub"), c.hostFree, true, function()
		flip("hostFree", c.hostFree, "server.setHostFree")
	end, c.fuelOn and 1 or 0.55)

	local hidden = pendingValue("menuHidden", shared.menuHidden == true)
	toggleRow(192, T("menu_hidden"), T("menu_hidden_sub"), hidden, true, function()
		flip("menuHidden", hidden, "server.setMenuHidden")
	end)

	local announce = pendingValue("announce", shared.announce ~= false)
	toggleRow(246, T("announce"), T("announce_sub"), announce, true, function()
		flip("announce", announce, "server.setAnnounce")
	end)

	-- actions
	card(0, 324, CW, 48)
	if button(T("refill_all"), -225, 324, 142, 36, BTN, WHITE, 16, not c.fuelOn) then
		ServerCall("server.refillAll")
		toast(T("toast_refilled"))
	end
	if button(T("clear_overrides"), -75, 324, 142, 36, BTN, WHITE, 16) then
		ServerCall("server.resetOverrides")
		toast(T("toast_cleared"))
	end
	armedButton("stats", T("reset_stats"), 75, 324, 142, 36, function()
		ServerCall("server.resetStats")
		toast(T("toast_stats_reset"))
	end)
	armedButton("all", T("reset_all"), 225, 324, 142, 36, function()
		resetHostSettings()
		toast(T("toast_all_reset"))
	end)
end

local function resetHud()
	setGaugeAutoHide(true)
	setSpeedHud(false)
	setSpeedUnit(1)
	setAltHud(false)
	setGaugeSize(2)
	setGaugePos(1)
	setGaugeCb(false)
end

local function resetPersonal()
	resetHud()
	setKbBind("jump")
	setPadBind("jump")
	setBoostKb("q")
	setBoostPad("interact")
	setFxMode(2)
	setAccent(1, true)
	setQuickKey("")
	setRememberTab(true)
end

-- Key button with a small reset on its right (keyboard / mouse).
local function keyPicker(cy, target, current, resetKey, resetText, onReset)
	local waiting = capturing and captureTarget == target
	local text = waiting and T("press_key") or (current == "" and T("menu_key_none") or bindLabel(current))
	if button(text, 134, cy, 170, 34, waiting and ACCENT or BTN, waiting and DARK or WHITE, 18) then
		if waiting then capturing = false else startCapture(target) end
	end
	if button(resetText, 260, cy, 70, 34, BTN, WHITE, 15, current == resetKey) then
		capturing = false
		onReset()
	end
end

-- Controller: step through the actions that can be used.
local function padPicker(cy, current, onSet)
	if button("<", 77, cy, 40, 34, BTN, WHITE, 22) then onSet(cycleList(PAD_ACTIONS, current, -1)) end
	if button(bindLabel(current), 176, cy, 150, 34, ACCENT, DARK, 18) then onSet(cycleList(PAD_ACTIONS, current, 1)) end
	if button(">", 275, cy, 40, 34, BTN, WHITE, 22) then onSet(cycleList(PAD_ACTIONS, current, 1)) end
end

-- Everything here only affects this player and is saved on this PC.
local function tabControls(c)
	local pad = nav.active
	local ba = (shared.boostOn == true) and 1 or 0.6

	local cy = settingRow(rowTop(1), T("flight_key"), pad and T("key_sub_pad") or T("key_sub_kb"), 300)
	if pad then
		padPicker(cy, padBind, setPadBind)
	else
		keyPicker(cy, "fly", kbBind, "jump", T("reset"), function() setKbBind("jump") end)
	end

	cy = settingRow(rowTop(2), T("boost_key"), T("boost_key_sub"), 300, ba)
	if pad then
		padPicker(cy, boostPad, setBoostPad)
	else
		keyPicker(cy, "boost", boostKb, "q", T("reset"), function() setBoostKb("q") end)
	end

	cy = settingRow(rowTop(3), T("menu_key"), T("menu_key_sub"), 300)
	if pad then
		label(T("kb_only"), RIGHT, cy, 18, WHITE, 0.5, "right middle", 200)
	else
		keyPicker(cy, "menu", quickKey, "", T("clear"), function() setQuickKey("") end)
	end

	choiceRow(rowTop(4), T("effects"), T("effects_sub"), { "fx_off", "fx_light", "fx_full" },
		pendingValue("fx", fxMode + 1), true, function(i)
			setPending("fx", i)
			setFxMode(i - 1)
		end)

	-- accent colour: one swatch per colour
	cy = settingRow(rowTop(5), T("accent"), T("accent_sub"), 300)
	for i, entry in ipairs(ACCENT_PALETTE) do
		local x = RIGHT - 18 - (#ACCENT_PALETTE - i) * 40
		UiPush()
			UiTranslate(x, cy)
			UiAlign("center middle")
			if i == accentIndex then
				UiColor(1, 1, 1, 0.9)
				UiRoundedRect(34, 34, 9)
			end
			UiColor(entry[2], entry[3], entry[4], 1)
			UiRoundedRect(28, 28, 7)
		UiPop()
		if hit(x, cy, 34, 34) then setAccent(i, true) end
	end

	toggleRow(rowTop(6), T("last_tab"), T("last_tab_sub"), rememberTab, true, function()
		setRememberTab(not rememberTab)
	end)

	cy = settingRow(rowTop(7), T("reset_personal"), T("reset_personal_sub"), 330)
	armedButton("personal", T("reset"), RIGHT - 90, cy, 180, 34, function()
		resetPersonal()
		toast(T("toast_personal_reset"))
	end)
end

local function tabHud(c)
	local autoHide = pendingValue("gauge", gaugeAutoHide)
	toggleRow(rowTop(1), T("gauge"), T("gauge_sub"), autoHide, true, function()
		setPending("gauge", not autoHide)
		setGaugeAutoHide(not autoHide)
	end)

	local showSpeed = pendingValue("speedhud", speedHud)
	toggleRow(rowTop(2), T("speed_hud"), T("speed_hud_sub"), showSpeed, true, function()
		setPending("speedhud", not showSpeed)
		setSpeedHud(not showSpeed)
	end)

	local showAlt = pendingValue("althud", altHud)
	toggleRow(rowTop(3), T("alt_hud"), T("alt_hud_sub"), showAlt, true, function()
		setPending("althud", not showAlt)
		setAltHud(not showAlt)
	end)

	choiceRow(rowTop(4), T("speed_unit"), nil, SPEED_UNIT_KEYS, pendingValue("sunit", speedUnit), true, function(i)
		setPending("sunit", i)
		setSpeedUnit(i)
	end, showSpeed and 1 or 0.5)

	choiceRow(rowTop(5), T("gauge_size"), nil, { "size_s", "size_m", "size_l" },
		pendingValue("gsize", gaugeSize), true, function(i)
			setPending("gsize", i)
			setGaugeSize(i)
		end)

	choiceRow(rowTop(6), T("gauge_pos"), nil, { "pos_bottom", "pos_top", "pos_left", "pos_right" },
		pendingValue("gpos", gaugePos), true, function(i)
			setPending("gpos", i)
			setGaugePos(i)
		end)

	choiceRow(rowTop(7), T("gauge_color"), nil, { "color_default", "color_cb" },
		pendingValue("gcb", gaugeCb and 2 or 1), true, function(i)
			setPending("gcb", i)
			setGaugeCb(i == 2)
		end)
end

local TAB_FUNCS = {
	flight = tabFlight, fuel = tabFuel, players = tabPlayers, admin = tabAdmin,
	controls = tabControls, hud = tabHud, stats = tabStats,
}


-- client: settings window -------------------------------------------------

-- Tabs in sidebar order. Host tools only show up for the host.
local function buildTabs(isHost, multiplayer)
	local tabs = {
		{ id = "flight", name = T("tab_flight"), section = "sec_game" },
		{ id = "fuel", name = T("tab_fuel"), section = "sec_game" },
	}
	if isHost then
		if multiplayer then
			tabs[#tabs + 1] = { id = "players", name = T("tab_players"), section = "sec_host" }
		end
		tabs[#tabs + 1] = { id = "admin", name = T("tab_admin"), section = "sec_host" }
	end
	tabs[#tabs + 1] = { id = "controls", name = T("tab_controls"), section = "sec_you" }
	tabs[#tabs + 1] = { id = "hud", name = T("tab_hud"), section = "sec_you" }
	tabs[#tabs + 1] = { id = "stats", name = T("tab_stats"), section = "sec_you" }
	return tabs
end

local function drawHeader(c, multiplayer, playerCount)
	label(T("title"), -400, -262, 34, WHITE, 1, "left middle", 420)
	if GetTime() < toastUntil then
		label(toastText, -400, -226, 17, ACCENT, 1, "left middle", 460)
	elseif c.blocked then
		label(T("not_allowed"), -400, -226, 17, BAD, 1, "left middle", 460)
	else
		local subtitle = c.isHost and T("host_view") or T("player_view")
		if multiplayer then subtitle = subtitle .. "   -   " .. T("host_stats", playerCount, c.flyingCount) end
		label(subtitle, -400, -226, 17, WHITE, 0.5, "left middle", 460)
	end

	-- version badge
	UiPush()
		UiTranslate(360, -255)
		UiAlign("center middle")
		UiColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.15)
		UiRoundedRect(96, 30, 15)
	UiPop()
	label("v" .. VERSION, 360, -255, 18, ACCENT, 1, "center middle", 84)

	UiPush()
		UiTranslate(0, -196)
		UiAlign("center middle")
		UiColor(1, 1, 1, 0.10)
		UiRect(PANEL_W - 40, 2)
	UiPop()
end

-- Tab buttons, grouped under small headings.
local function drawSidebar(tabs)
	card(SIDEBAR_X, BODY_TOP + BODY_H / 2, SIDEBAR_W, BODY_H)
	local y, section = BODY_TOP + 6, nil
	for i = 1, #tabs do
		local entry = tabs[i]
		if entry.section ~= section then
			section = entry.section
			label(string.upper(T(section)), SIDEBAR_X - (SIDEBAR_W - 24) / 2 + 4, y + 13, 13, WHITE, 0.4, "left middle")
			y = y + 24
		end
		local active = (tab == entry.id)
		if button(entry.name, SIDEBAR_X, y + 19, SIDEBAR_W - 24, 36,
			active and ACCENT or BTN, active and DARK or WHITE, 19) then
			tab = entry.id
			capturing = false
		end
		y = y + 42
	end
end

local function drawFooter(isHost)
	UiPush()
		UiTranslate(0, 216)
		UiAlign("center middle")
		UiColor(1, 1, 1, 0.10)
		UiRect(PANEL_W - 40, 2)
	UiPop()

	local text = T("version_line", VERSION, REVISION)
	if nav.active then
		text = T("hint_pad")
	elseif not isHost and (tab == "flight" or tab == "fuel") then
		text = T("host_only_note")
	end
	label(text, -400, 258, 15, WHITE, 0.45, "left middle", 560)
	if button(T("close"), 325, 258, 150, 42, ACCENT, DARK, 24) then
		settingsOpen = false
	end
end

function client.draw()
	if not accentLoaded then
		accentLoaded = true
		setAccent(GetInt("savegame.mod.accent"), false)
	end

	if not settingsOpen then
		if shared.fuelEnabled then drawGauge() end
		if speedHud or altHud then drawSpeed() end
		drawBoost()
		drawNote()
		return
	end

	UiMakeInteractive()

	local me = GetLocalPlayer()
	local isHost = IsPlayerHost(me)
	local playerCount = GetPlayerCount()
	local multiplayer = playerCount > 1

	nav.active = usingPad()
	nav.accept = nav.active and InputPressed("menu_accept") and GetTime() - openedAt > 0.2
	nav.items = {}
	nav.offset = 0
	nav.offsetY = 0

	-- what the screen shows right now (clicked values count immediately)
	local c = {
		isHost = isHost,
		playerCount = playerCount,
		flyingCount = #(shared.jetting or {}),
		enabled = pendingValue("enabled", shared.enabled ~= false),
		thrust = pendingValue("thrust", shared.thrustPct or THRUST_DEFAULT),
		smooth = pendingValue("smooth", shared.smooth ~= false),
		cap = pendingValue("cap", shared.speedCap or 0),
		fuelOn = pendingValue("fuelOn", shared.fuelEnabled == true),
		tank = pendingValue("tank", shared.fuelCap or FUEL_DEFAULT),
		refill = pendingValue("refill", shared.refill or REFILL_DEFAULT),
		refillDelay = pendingValue("delay", shared.refillDelay or DELAY_DEFAULT),
		mode = pendingValue("mode", shared.mode or 1),
		hover = pendingValue("hover", shared.hover ~= false),
		boostOn = pendingValue("boostOn", shared.boostOn == true),
		boostCd = pendingValue("boostCd", shared.boostCd or BOOST_CD_DEFAULT),
		boostCost = pendingValue("boostCost", shared.boostCost or BOOST_COST_DEFAULT),
		upgrades = pendingValue("upgrades", shared.upgrades == true),
		ceiling = pendingValue("ceiling", shared.ceiling or 0),
		hostFree = pendingValue("hostFree", shared.hostFree == true),
		restrict = pendingValue("restrict", shared.restrict == true),
		blocked = (shared.restrict == true) and not isHost and not inAllowedList(me),
	}

	local tabs = buildTabs(isHost, multiplayer)
	local known = false
	for i = 1, #tabs do
		if tabs[i].id == tab then known = true end
	end
	if not known then tab = "flight" end
	if tab ~= lastTab then
		lastTab = tab
		SetString("savegame.mod.last_tab", tab)
	end

	UiPush()
		-- dim the world
		UiColor(0, 0, 0, 0.55)
		UiRect(UiWidth(), UiHeight())

		UiTranslate(UiCenter(), UiMiddle())

		-- small screens: shrink the whole window so it always fits
		local fit = math.min(1, (UiHeight() - 24) / PANEL_H, (UiWidth() - 24) / PANEL_W)
		if fit < 1 then UiScale(fit) end

		UiAlign("center middle")

		-- panel: soft shadow, thin border, body
		UiColor(0, 0, 0, 0.35)
		UiRoundedRect(PANEL_W + 28, PANEL_H + 28, 32)
		UiColor(1, 1, 1, 0.10)
		UiRoundedRect(PANEL_W + 4, PANEL_H + 4, 22)
		UiColor(PANEL[1], PANEL[2], PANEL[3], 0.98)
		UiRoundedRect(PANEL_W, PANEL_H, 20)

		drawHeader(c, multiplayer, playerCount)
		drawSidebar(tabs)

		-- content
		UiPush()
			UiTranslate(CONTENT_X, BODY_TOP)
			nav.offset = CONTENT_X
			nav.offsetY = BODY_TOP
			local drawTab = TAB_FUNCS[tab] or tabFlight
			drawTab(c)
		UiPop()
		nav.offset = 0
		nav.offsetY = 0

		drawFooter(isHost)
	UiPop()

	drawNote()
	handleControllerInput(tabs)
end

end

buildClient()