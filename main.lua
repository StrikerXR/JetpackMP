#version 2

-- Jetpack (Multiplayer)
-- Based on the built-in Jetpack by Tuxedo Labs.
--
-- The server does the actual flying (thrust, fuel, limits). Clients handle
-- sound, exhaust effects, the fuel gauge and the settings screen.
-- Saved settings live under savegame.mod.* and keep their names between
-- versions so nobody loses their setup on update.
--
-- File layout:
--   1. constants and shared helpers
--   2. server scope (flying, fuel, stats, host setters)
--   3. client scope (sound, effects, HUD, settings menu)
--
-- The changelog lives in the About tab of the in-game settings menu.
-- Accent colours are saved by position, so new ones only go at the end.
-- Server setters clamp every value themselves, whatever the client sent.

local VERSION = "28.6"
local REVISION = 1

local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt

local THRUST_BASE = 0.3
local SOUND_VOLUME = 0.5
local THRUST_DEFAULT = 100

local FUEL_MIN, FUEL_MAX, FUEL_DEFAULT = 2, 30, 6
local REFILL_DEFAULT, REFILL_MIN, REFILL_MAX, REFILL_STEP = 2.5, 1, 10, 0.5
local FUEL_SYNC_INTERVAL = 0.2
local FUEL_SNAP_DISTANCE = 0.5

local RAMP_SECONDS = 0.35
local RAMP_FLOOR = 0.15
local CAP_MIN, CAP_MAX, CAP_STEP = 10, 60, 5

local DELAY_MIN, DELAY_MAX, DELAY_STEP, DELAY_DEFAULT = 0, 5, 0.5, 0
local CEIL_MIN, CEIL_MAX, CEIL_STEP = 10, 200, 10

local BIND_RESEND = 3
local GAUGE_HIDE_DELAY = 3
local GAUGE_FADE_RATE = 6
local FX_RANGE = 80  -- other players' exhaust effects are skipped beyond this distance (metres)

local BOOST_TIME, BOOST_MUL = 0.4, 2.6
local BOOST_CD_MIN, BOOST_CD_MAX, BOOST_CD_DEFAULT = 3, 30, 8
local BOOST_COST_MAX, BOOST_COST_STEP, BOOST_COST_DEFAULT = 5, 0.5, 1.5
local MUL_MIN, MUL_STEP, MUL_T_MAX, MUL_F_MAX = 25, 25, 200, 400

local FLAME_DEFAULT = 1  -- orange
local ACCENT_DEFAULT = 11  -- mint
local FLAME_PALETTE = {
	{ 1.0, 0.75, 0.3,  1.0, 0.25, 0.1 },
	{ 0.6, 0.85, 1.0,  0.2, 0.4, 1.0 },
	{ 0.7, 1.0, 0.5,   0.1, 0.8, 0.3 },
	{ 0.85, 0.65, 1.0, 0.5, 0.15, 0.9 },
	{ 1.0, 0.7, 0.85,  0.95, 0.2, 0.5 },
}


-- shared helpers ------------------------------------------------------

local function num(v, default)
	v = tonumber(v)
	if v == nil or v ~= v then return default end
	return v
end

local function round(v) return floor(v + 0.5) end
local function snap(v, step) return floor(v / step + 0.5) * step end
local function clamp(v, lo, hi) return max(lo, min(hi, v)) end

-- value snapped to a step and limited, or 0 meaning "off"
local function clampOff(v, step, lo, hi)
	v = num(v, 0)
	if v <= 0 then return 0 end
	return clamp(snap(v, step), lo, hi)
end

local function clampThrust(v) return clamp(snap(num(v, THRUST_DEFAULT), 10), 50, 150) end
local function clampFuel(v) return clamp(round(num(v, FUEL_DEFAULT)), FUEL_MIN, FUEL_MAX) end
local function clampCap(v) return clampOff(v, CAP_STEP, CAP_MIN, CAP_MAX) end
local function clampCeiling(v) return clampOff(v, CEIL_STEP, CEIL_MIN, CEIL_MAX) end
local function clampRefill(v) return clamp(snap(num(v, REFILL_DEFAULT), REFILL_STEP), REFILL_MIN, REFILL_MAX) end
local function clampDelay(v) return clamp(snap(num(v, DELAY_DEFAULT), DELAY_STEP), DELAY_MIN, DELAY_MAX) end
local function clampMul(v, hi) return clamp(snap(num(v, 100), MUL_STEP), MUL_MIN, hi) end
local function clampBoostCd(v) return clamp(round(num(v, BOOST_CD_DEFAULT)), BOOST_CD_MIN, BOOST_CD_MAX) end
local function clampBoostCost(v) return clamp(snap(num(v, BOOST_COST_DEFAULT), BOOST_COST_STEP), 0, BOOST_COST_MAX) end

local PROFILES = {
	original = { thrust = 100, cap = 0,  smooth = true,  fuel = false, tank = FUEL_DEFAULT },
	balanced = { thrust = 100, cap = 25, smooth = true,  fuel = true,  tank = 8 },
	turbo    = { thrust = 150, cap = 40, smooth = false, fuel = false, tank = FUEL_DEFAULT },
}
local PROFILE_NAMES = {
	original = "Original", balanced = "Balanced", turbo = "Turbo",
	custom1 = "Custom 1", custom2 = "Custom 2",
}

local function sameList(a, b)
	local n = #a
	if n ~= #b then return false end
	for i = 1, n do
		if a[i] ~= b[i] then return false end
	end
	return true
end

local function copyList(list)
	local out = {}
	for i = 1, #list do out[i] = list[i] end
	return out
end

local function clearList(list)
	for i = #list, 1, -1 do list[i] = nil end
end

-- pos is optional, pass it when the caller already has the player's position
local function groundProbe(p, pos)
	if not IsPlayerValid(p) then return false end
	pos = pos or GetPlayerTransform(p).pos
	local hit, dist = QueryRaycast(Vec(pos[1], pos[2] + 0.25, pos[3]), Vec(0, -1, 0), 0.4)
	return hit and dist <= 0.4
end

local function isGrounded(p, pos)
	local ok, result = pcall(groundProbe, p, pos)
	return ok and result == true
end

local function rampPower(held)
	local s = min(1, held / RAMP_SECONDS)
	return RAMP_FLOOR + (1 - RAMP_FLOOR) * s * s * (3 - 2 * s)
end

local function capSpeed(oldVel, newVel, cap)
	if cap <= 0 then return newVel end
	local newSpeed = VecLength(newVel)
	local limit = max(cap, VecLength(oldVel))
	if newSpeed <= limit or newSpeed == 0 then return newVel end
	return VecScale(newVel, limit / newSpeed)
end

local VALID_INPUTS = {}
for _, name in ipairs({
	"jump", "crouch", "interact", "flashlight", "grab", "usetool",
	"space", "shift", "ctrl", "alt", "tab", "rmb", "mmb", "return", "backspace",
	"uparrow", "downarrow", "leftarrow", "rightarrow",
	"home", "end", "pgup", "pgdown", "insert", "delete",
}) do
	VALID_INPUTS[name] = true
end
for c = 97, 122 do VALID_INPUTS[string.char(c)] = true end
for d = 0, 9 do VALID_INPUTS[tostring(d)] = true end
for f = 1, 12 do VALID_INPUTS["f" .. f] = true end

local LEGACY_INPUTS = { sprint = "shift" }

local function normalizeBind(bind)
	if type(bind) ~= "string" then return nil end
	bind = LEGACY_INPUTS[bind] or bind
	return VALID_INPUTS[bind] and bind or nil
end

local function inputHeld(name, player)
	local ok, down
	if player then
		ok, down = pcall(InputDown, name, player)
	else
		ok, down = pcall(InputDown, name)
	end
	return ok and down == true
end

local UPGRADES = {
	{ id = "tank",   name = "Tank",   at = { 60, 240, 720 },   bonus = { 0.15, 0.30, 0.50 } },
	{ id = "thrust", name = "Thrust", at = { 90, 360, 1080 },  bonus = { 0.05, 0.10, 0.15 } },
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

local function describeProfile(p)
	local capText = p.cap == 0 and "no speed cap" or (p.cap .. " m/s cap")
	local fuelText = p.fuel and ("fuel " .. p.tank .. " s") or "unlimited fuel"
	return string.format("thrust %d%%, %s, %s", p.thrust, capText, fuelText)
end

-- Changelog shown in the About tab, newest first. Keep each entry to 10 short lines.
local CHANGELOG = {
	{
		version = "28.6", title = "Polish and bug fixes",
		notes = {
			"Menu: new About tab (this one) holds the changelog; sidebar tightened.",
			"Key binding: capture no longer stays armed after the menu closes.",
			"Key binding: flight, boost and menu keys can no longer share a key.",
			"Profiles and Reset all no longer refill tanks or send stray messages.",
			"Fuel sync now notices players swapping in and out at the same count.",
			"Fuel gauge no longer fades out while the tank is still refilling.",
			"Left players are cleaned up on a timer; stats also save on landing.",
			"Controller: disabled buttons skip focus; tab switching moves focus.",
			"Performance: shared lists only update on change, fewer allocations,",
			"distant exhaust skipped past 80 m, one ground check per client tick.",
		},
	},
	{
		version = "28.5", title = "Cleanup",
		notes = {
			"Server setters are generated from small tables instead of copy-pasted.",
			"Settings rows return clicks instead of callbacks (no per-frame closures).",
			"Per-frame work trimmed (cached tab lists, no string building in T()).",
			"Default accent colour (menu and HUD) is now Mint; saved accents are kept.",
			"Flame colours are unchanged.",
		},
	},
}


do  -- server scope

local S = {
	on = true, thrust = THRUST_DEFAULT, cap = 0, smooth = true,
	restrict = false, fuelOn = false, tank = FUEL_DEFAULT, refill = REFILL_DEFAULT,
	delay = DELAY_DEFAULT, ceiling = 0, hostFree = false,
	hover = true, boostOn = false, boostCd = BOOST_CD_DEFAULT, boostCost = BOOST_COST_DEFAULT,
	upgrades = false, menuHidden = false, announce = true,
	noteSeq = 0, playerCount = 0,
	errorAt = -100, lastError = "",
	fuelTimer = 0, statsTimer = 0, saveTimer = 0, cleanTimer = 0,
	lastJetting = {}, lastBoosting = {}, lastFuelValues = {}, lastFuelIds = {}, lastStats = {},
	lastShared = {},
}

-- which shared key mirrors each setting in S
local SHARE = {
	on = "enabled", thrust = "thrustPct", cap = "speedCap", smooth = "smooth",
	fuelOn = "fuelEnabled", tank = "fuelCap", refill = "refill", delay = "refillDelay",
	ceiling = "ceiling", hostFree = "hostFree", hover = "hover", boostOn = "boostOn",
	boostCd = "boostCd", boostCost = "boostCost", upgrades = "upgrades",
	menuHidden = "menuHidden", announce = "announce", restrict = "restrict",
}

-- per-player stores, keyed by player id
local R = {}
for _, name in ipairs({
	"allowed", "binds", "boostBinds", "flames", "fuel", "ramp", "baseY", "groundedFor",
	"ovT", "ovF", "boostCdT", "boostLeft", "boostPrev",
	"stats", "airborne", "lastX", "lastZ",
}) do
	R[name] = {}
end

-- per-tick scratch lists, reused so the server does not allocate every tick
local flyBuf, boostBuf = {}, {}
local EMPTY = {}

local function validPlayer(pid) return type(pid) == "number" and IsPlayerValid(pid) end

local function notify(text, force)
	if not S.announce and not force then return end
	S.noteSeq = S.noteSeq + 1
	shared.noteText = text
	shared.noteSeq = S.noteSeq
end

-- Writes a list to shared only when it really changed, so clients are not re-synced for nothing.
local function publishList(key, list)
	if sameList(list, S.lastShared[key] or EMPTY) then return end
	S.lastShared[key] = list
	shared[key] = list
end

local function publishAllowed()
	local list = {}
	for pid, on in pairs(R.allowed) do
		if on and IsPlayerValid(pid) then
			list[#list + 1] = pid
		else
			R.allowed[pid] = nil
		end
	end
	table.sort(list)
	publishList("allowed", list)
end

local function publishFuel(force)
	local ids, values = {}, {}
	local players = GetAllPlayers()
	for i = 1, #players do
		local p = players[i]
		ids[i] = p
		values[i] = round((R.fuel[p] or S.tank) * 10) / 10
	end
	if force or not sameList(values, S.lastFuelValues) or not sameList(ids, S.lastFuelIds) then
		shared.fuelIds = ids
		shared.fuelVals = values
		S.lastFuelValues = values
		S.lastFuelIds = ids
	end
end

local function publishMuls()
	local list = {}
	for _, p in ipairs(GetAllPlayers()) do
		local t, f = R.ovT[p] or 100, R.ovF[p] or 100
		if t ~= 100 or f ~= 100 then
			list[#list + 1] = p
			list[#list + 1] = t
			list[#list + 1] = f
		end
	end
	publishList("pm", list)
end

local function publishFlames()
	local list = {}
	for _, p in ipairs(GetAllPlayers()) do
		local flame = R.flames[p]
		if flame and flame ~= FLAME_DEFAULT then
			list[#list + 1] = p
			list[#list + 1] = flame
		end
	end
	publishList("pf", list)
end

local function statKey(p)
	local ok, name = pcall(GetPlayerName, p)
	name = ok and tostring(name) or ""
	name = name:gsub("[^%w]", ""):sub(1, 20)
	if name == "" then name = "player" end
	return "savegame.mod.st." .. name
end

local function statsFor(p)
	local s = R.stats[p]
	if s then return s end
	local key = statKey(p)
	s = {
		key = key, dirty = false,
		peak = GetInt(key .. ".peak"), dist = GetInt(key .. ".dist"),
		time = GetInt(key .. ".time"), boosts = GetInt(key .. ".boosts"),
	}
	R.stats[p] = s
	return s
end

local function saveStat(s)
	if not s or not s.dirty then return end
	s.dirty = false
	SetInt(s.key .. ".peak", floor(s.peak))
	SetInt(s.key .. ".dist", floor(s.dist))
	SetInt(s.key .. ".time", floor(s.time))
	SetInt(s.key .. ".boosts", s.boosts)
end

local function publishStats(force)
	local list, n = {}, 0
	for _, p in ipairs(GetAllPlayers()) do
		local s = R.stats[p]
		if s then
			list[n + 1], list[n + 2], list[n + 3], list[n + 4], list[n + 5] =
				p, floor(s.peak), floor(s.dist), floor(s.time), s.boosts
			n = n + 5
		end
	end
	if force or not sameList(list, S.lastStats) then
		shared.ps = list
		S.lastStats = list
	end
end

local function forgetLeftPlayers()
	for pid, s in pairs(R.stats) do
		if not IsPlayerValid(pid) then saveStat(s) end
	end
	for _, store in pairs(R) do
		for pid in pairs(store) do
			if not IsPlayerValid(pid) then store[pid] = nil end
		end
	end
	publishAllowed()
	publishMuls()
	publishFlames()
end

local function canFly(p)
	if not S.on then return false end
	return not (S.restrict and not IsPlayerHost(p) and not R.allowed[p])
end

local function publishCustom(slot)
	local p = PROFILES["custom" .. slot]
	shared["custom" .. slot] = p and { p.thrust, p.cap, p.smooth and 1 or 0, p.fuel and 1 or 0, p.tank } or {}
end

-- setting setters ------------------------------------------------------
-- Everything below is called from the host's settings screen. The server
-- clamps every value itself, whatever the client sent.

-- number setting: clamp, keep in S, mirror to shared, save (scaled to an int if needed)
local function defNum(fname, field, saveKey, clampFn, scale, after)
	local shareKey = SHARE[field]
	server[fname] = function(v)
		v = clampFn(v)
		S[field] = v
		shared[shareKey] = v
		SetInt(saveKey, scale and round(v * scale) or v)
		if after then after(v) end
	end
end

-- on/off setting. inv = the saved flag means "off" (e.g. savegame.mod.disabled).
-- after(on, silent, old) runs once the value is stored; old is the previous value.
local function defBool(fname, field, saveKey, inv, after)
	local shareKey = SHARE[field]
	server[fname] = function(on, silent)
		on = on and true or false
		local old = S[field]
		S[field] = on
		shared[shareKey] = on
		if saveKey then SetInt(saveKey, (on ~= inv) and 1 or 0) end
		if after then after(on, silent, old) end
	end
end

defNum("setThrustPct", "thrust", "savegame.mod.thrustpct", clampThrust)
defNum("setSpeedCap", "cap", "savegame.mod.speedcap", clampCap)
defNum("setRefill", "refill", "savegame.mod.refill_x10", clampRefill, 10)
defNum("setRefillDelay", "delay", "savegame.mod.refill_delay_x10", clampDelay, 10)
defNum("setCeiling", "ceiling", "savegame.mod.ceiling", clampCeiling)
defNum("setBoostCd", "boostCd", "savegame.mod.boost_cd", clampBoostCd)
defNum("setBoostCost", "boostCost", "savegame.mod.boost_cost_x10", clampBoostCost, 10,
	function() SetInt("savegame.mod.boost_cost_set", 1) end)
defNum("setFuelCap", "tank", "savegame.mod.fuel_cap", clampFuel, nil, function(v)
	for pid, amount in pairs(R.fuel) do
		if amount > v then R.fuel[pid] = v end
	end
end)

defBool("setEnabled", "on", "savegame.mod.disabled", true)
defBool("setSmooth", "smooth", "savegame.mod.noramp", true)
defBool("setHover", "hover", "savegame.mod.hover_off", true)
defBool("setHostFree", "hostFree")
defBool("setRestrict", "restrict", nil, false, publishAllowed)
defBool("setBoostOn", "boostOn", "savegame.mod.boost_on", false, function(on)
	notify(on and "Host turned boost on" or "Host turned boost off")
end)
defBool("setUpgrades", "upgrades", "savegame.mod.upgrades_on", false, function(on)
	notify(on and "Host turned upgrades on" or "Host turned upgrades off")
end)
defBool("setMenuHidden", "menuHidden", "savegame.mod.menu_hidden", false, function(on, silent)
	if silent ~= true then
		notify(on and "Host hid the Jetpack settings menu" or "Host showed the Jetpack settings menu", true)
	end
end)
defBool("setAnnounce", "announce", "savegame.mod.quiet", true, function(on, silent)
	if silent ~= true then
		notify(on and "Host turned settings messages on" or "Host turned settings messages off", true)
	end
end)
-- Only a real on/off change resets everyone's fuel (applying a profile with fuel already on must not).
defBool("setFuelEnabled", "fuelOn", "savegame.mod.fuel_enabled", false, function(on, _, old)
	if on == old then return end
	R.fuel = {}
	S.lastFuelValues = {}
	S.lastFuelIds = {}
	shared.fuelIds = {}
	shared.fuelVals = {}
	if on then publishFuel(true) end
end)

function server.init()
	S.lastShared = {}
	S.lastFuelValues, S.lastFuelIds = {}, {}

	S.menuHidden = GetInt("savegame.mod.menu_hidden") == 1
	S.announce = GetInt("savegame.mod.quiet") ~= 1
	S.on = GetInt("savegame.mod.disabled") ~= 1
	S.smooth = GetInt("savegame.mod.noramp") ~= 1
	S.cap = clampCap(GetInt("savegame.mod.speedcap"))

	local v = GetInt("savegame.mod.thrustpct")
	if v > 0 then S.thrust = clampThrust(v) end

	S.fuelOn = GetInt("savegame.mod.fuel_enabled") == 1
	v = GetInt("savegame.mod.fuel_cap")
	S.tank = v > 0 and clampFuel(v) or FUEL_DEFAULT

	v = GetInt("savegame.mod.refill_x10")
	if v > 0 then S.refill = clampRefill(v / 10) end

	S.delay = clampDelay(GetInt("savegame.mod.refill_delay_x10") / 10)
	S.ceiling = clampCeiling(GetInt("savegame.mod.ceiling"))

	S.hover = GetInt("savegame.mod.hover_off") ~= 1
	S.boostOn = GetInt("savegame.mod.boost_on") == 1
	v = GetInt("savegame.mod.boost_cd")
	if v > 0 then S.boostCd = clampBoostCd(v) end
	v = GetInt("savegame.mod.boost_cost_x10")
	if v > 0 or GetInt("savegame.mod.boost_cost_set") == 1 then S.boostCost = clampBoostCost(v / 10) end
	S.upgrades = GetInt("savegame.mod.upgrades_on") == 1

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

	for field, key in pairs(SHARE) do shared[key] = S[field] end
	shared.fuelIds, shared.fuelVals, shared.allowed = {}, {}, {}
	shared.jetting, shared.boosting, shared.pm, shared.ps, shared.pf = {}, {}, {}, {}, {}
	shared.noteSeq = 0
	shared.noteText = ""
end

function server.setAllowed(pid, on)
	if not validPlayer(pid) then return end
	R.allowed[pid] = on and true or nil
	publishAllowed()
end

function server.setAllowedAll(on)
	for _, p in ipairs(GetAllPlayers()) do
		if not IsPlayerHost(p) then R.allowed[p] = on and true or nil end
	end
	publishAllowed()
end

function server.refillAll()
	if not S.fuelOn then return end
	for _, p in ipairs(GetAllPlayers()) do R.fuel[p] = S.tank end
	publishFuel(true)
end

function server.refillPlayer(pid)
	if not S.fuelOn or not validPlayer(pid) then return end
	R.fuel[pid] = S.tank
	publishFuel(true)
end

function server.setPlayerFlight(pid, on)
	if not validPlayer(pid) or IsPlayerHost(pid) then return end
	if on then
		R.allowed[pid] = true
	else
		if not S.restrict then
			-- blocking one player turns approval mode on and keeps everyone else allowed
			for _, p in ipairs(GetAllPlayers()) do
				if not IsPlayerHost(p) then R.allowed[p] = true end
			end
			S.restrict = true
			shared.restrict = true
		end
		R.allowed[pid] = nil
	end
	publishAllowed()
end

function server.resetPlayer(pid)
	if type(pid) ~= "number" then return end
	R.ovT[pid], R.ovF[pid] = nil, nil
	publishMuls()
end

function server.resetOverrides()
	R.ovT, R.ovF = {}, {}
	publishMuls()
	notify("Host cleared all player overrides")
end

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

function server.setPlayerMul(pid, kind, pct)
	if not validPlayer(pid) then return end
	if kind == "thrust" then
		R.ovT[pid] = clampMul(pct, MUL_T_MAX)
	elseif kind == "fuel" then
		R.ovF[pid] = clampMul(pct, MUL_F_MAX)
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

function server.saveCustom(slot)
	slot = floor(num(slot, 0))
	if slot ~= 1 and slot ~= 2 then return end
	local p = { thrust = S.thrust, cap = S.cap, smooth = S.smooth, fuel = S.fuelOn, tank = S.tank }
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
	server.setHover(true)
	server.setBoostOn(false)
	server.setBoostCd(BOOST_CD_DEFAULT)
	server.setBoostCost(BOOST_COST_DEFAULT)
	server.setUpgrades(false)
	R.ovT, R.ovF = {}, {}
	publishMuls()
	R.allowed = {}
	server.setRestrict(false)
	notify("Host reset all Jetpack settings")
end

function server.setPlayerBind(pid, bind, boostBind, flame)
	if not validPlayer(pid) then return end
	bind = normalizeBind(bind)
	if bind then R.binds[pid] = bind end
	boostBind = normalizeBind(boostBind)
	if boostBind then R.boostBinds[pid] = boostBind end
	flame = floor(num(flame, FLAME_DEFAULT))
	-- this call repeats every few seconds, so only publish when the flame really changed
	if FLAME_PALETTE[flame] and R.flames[pid] ~= flame then
		R.flames[pid] = flame
		publishFlames()
	end
end

local function checkPlayers()
	local count = GetPlayerCount()
	if count ~= S.playerCount then
		S.playerCount = count
		forgetLeftPlayers()
	end
end

function server.tick(dt)
	pcall(checkPlayers)
	-- also clean up on a timer: one player leaving as another joins keeps the count the same
	S.cleanTimer = S.cleanTimer + (dt or 0.02)
	if S.cleanTimer >= 2 then
		S.cleanTimer = 0
		pcall(forgetLeftPlayers)
	end
end

local function reportError(err)
	err = tostring(err)
	local now = GetTime()
	if now - S.errorAt < (err == S.lastError and 30 or 5) then return end
	S.errorAt, S.lastError = now, err
	DebugPrint("Jetpack (Multiplayer) error: " .. err)
end

-- One player, one physics step.
local function stepOne(p, dt, flying, boosting)
	local s = statsFor(p)
	local health = GetPlayerHealth(p)
	local inVehicle = GetPlayerVehicle(p) ~= 0
	local free = S.hostFree and IsPlayerHost(p)
	local fuelOn = S.fuelOn
	local fuel = R.fuel
	local up = S.upgrades

	if fuelOn and (fuel[p] == nil or health <= 0 or free or fuel[p] > S.tank) then
		fuel[p] = S.tank
	end

	local endurance = (R.ovF[p] or 100) / 100 * (1 + upBonus(UPGRADES[1], s.time, up))
	local thrustMul = (R.ovT[p] or 100) / 100 * (1 + upBonus(UPGRADES[2], s.time, up))
	local refillMul = 1 + upBonus(UPGRADES[3], s.time, up)

	local wantsToFly = canFly(p) and health > 0 and not inVehicle and inputHeld(R.binds[p] or "jump", p)
	local hasFuel = not fuelOn or free or fuel[p] > 0.02
	local flyingNow = wantsToFly and hasFuel

	local pos = GetPlayerTransform(p).pos
	local grounded = inVehicle or isGrounded(p, pos)

	if grounded or health <= 0 or R.baseY[p] == nil then R.baseY[p] = pos[2] end
	local ceilRoom = S.ceiling > 0 and (S.ceiling - (pos[2] - R.baseY[p])) or nil

	-- Boost: rising edge on the boost key while flying, once the cooldown is over.
	local boostHeld = S.boostOn and inputHeld(R.boostBinds[p] or "q", p) or false
	local cd = max(0, (R.boostCdT[p] or 0) - dt)
	R.boostCdT[p] = cd
	if flyingNow and boostHeld and not R.boostPrev[p] and cd <= 0 then
		local cost = S.boostCost
		if not fuelOn or free or cost <= 0 or fuel[p] >= cost then
			R.boostLeft[p] = BOOST_TIME
			R.boostCdT[p] = S.boostCd
			if fuelOn and not free then fuel[p] = max(0, fuel[p] - cost) end
			s.boosts = s.boosts + 1
			s.dirty = true
		end
	end
	R.boostPrev[p] = boostHeld

	if flyingNow then
		R.groundedFor[p] = 0
		R.ramp[p] = (R.ramp[p] or 0) + dt
		s.time = s.time + dt
		s.dirty = true

		local power = S.smooth and rampPower(R.ramp[p]) or 1
		local boostK, capK = 1, 1
		local left = R.boostLeft[p] or 0
		if left > 0 then
			R.boostLeft[p] = left - dt
			boostK, capK, power = BOOST_MUL, 1.5, 1
			boosting[#boosting + 1] = p
		end

		local thrust = THRUST_BASE * S.thrust / 100 * thrustMul * power * boostK
		local vel = GetPlayerVelocity(p)
		local push = TransformToParentVec(GetPlayerCameraTransform(p), Vec(0, thrust, 0))

		local assist = S.hover and inputHeld("crouch", p)
		if assist then push = Vec(push[1], 0, push[3]) end

		local newVel = capSpeed(vel, VecAdd(vel, push), S.cap * capK)
		if assist then
			-- pull vertical speed towards what cancels the next step of gravity
			local vy = newVel[2]
			newVel = Vec(newVel[1], vy + (10 * dt - vy) * min(1, dt * 14), newVel[3])
		end
		if ceilRoom then
			local vmax = ceilRoom > 0 and sqrt(20 * ceilRoom) or 0
			if newVel[2] > vmax then newVel = Vec(newVel[1], vmax, newVel[3]) end
		end
		SetPlayerVelocity(newVel, p)
		flying[#flying + 1] = p
		if fuelOn and not free then fuel[p] = max(0, fuel[p] - dt / endurance) end
	else
		R.ramp[p] = max(0, (R.ramp[p] or 0) - dt * 3)
		R.boostLeft[p] = 0
		local gf = grounded and ((R.groundedFor[p] or 0) + dt) or 0
		R.groundedFor[p] = gf
		if fuelOn and grounded and gf >= S.delay then
			fuel[p] = min(S.tank, fuel[p] + dt * S.tank / S.refill * refillMul)
		end
	end

	-- Flight stats: peak height above take-off and horizontal distance while airborne.
	if flyingNow then R.airborne[p] = true end
	if grounded or health <= 0 then
		if R.airborne[p] then saveStat(s) end  -- just landed: write the stats out
		R.airborne[p] = false
	end
	local moved = 0
	local lx = R.lastX[p]
	if lx then
		local dx, dz = pos[1] - lx, pos[3] - R.lastZ[p]
		moved = sqrt(dx * dx + dz * dz)
	end
	R.lastX[p], R.lastZ[p] = pos[1], pos[3]
	if R.airborne[p] and moved < 20 then
		s.dist = s.dist + moved
		local h = pos[2] - R.baseY[p]
		if h > s.peak then s.peak = h end
		s.dirty = true
	end
end

local function stepPlayers(dt)
	clearList(flyBuf)
	clearList(boostBuf)
	for _, p in ipairs(GetAllPlayers()) do
		-- one broken player can never stop the others
		local ok, err = pcall(stepOne, p, dt, flyBuf, boostBuf)
		if not ok then reportError(err) end
	end

	if not sameList(flyBuf, S.lastJetting) then
		local copy = copyList(flyBuf)
		shared.jetting = copy
		S.lastJetting = copy
	end
	if not sameList(boostBuf, S.lastBoosting) then
		local copy = copyList(boostBuf)
		shared.boosting = copy
		S.lastBoosting = copy
	end

	if S.fuelOn then
		S.fuelTimer = S.fuelTimer + dt
		if S.fuelTimer >= FUEL_SYNC_INTERVAL then
			S.fuelTimer = 0
			publishFuel(false)
		end
	end

	S.statsTimer = S.statsTimer + dt
	if S.statsTimer >= 0.5 then
		S.statsTimer = 0
		publishStats(false)
	end
	S.saveTimer = S.saveTimer + dt
	if S.saveTimer >= 10 then
		S.saveTimer = 0
		for _, s in pairs(R.stats) do saveStat(s) end
	end
end

function server.update(dt)
	local ok, err = pcall(stepPlayers, dt)
	if not ok then reportError(err) end
end

end  -- server scope


local function buildClient()  -- client scope

-- text (English only)
local STRINGS = {
	title = "Jetpack Settings", host_view = "Host settings", player_view = "Player view",
	host_stats = "%d players   -   %d flying", close = "Close", on = "On", off = "Off",
	version_line = "Version %s   -   Revision %d",
	hint_pad = "Confirm: select    Cancel: close    LB / RB: tabs",
	host_only_note = "Only the host can change these settings.",
	not_allowed = "The host has not allowed you to use the jetpack.",

	sec_game = "Game", sec_host = "Host tools", sec_you = "You",
	tab_flight = "Flight", tab_fuel = "Fuel & Boost", tab_players = "Players", tab_admin = "Admin",
	tab_controls = "Controls", tab_hud = "HUD", tab_stats = "Stats", tab_about = "About",

	jetpack = "Jetpack", jetpack_sub = "Turn the jetpack on or off for everyone",
	thrust = "Thrust", thrust_sub = "%d%% - %d%%, where 100%% is the original",
	speed_cap = "Speed cap", speed_cap_sub = "The fastest the jetpack can push you",
	speed_value = "%d m/s", speed_off = "No limit",
	ceiling = "Height limit", ceiling_sub = "How far above the ground the jetpack can lift you",
	smooth = "Smooth take-off", smooth_sub = "Thrust builds up gently instead of full power at once",
	hover_assist = "Hover assist", hover_assist_sub = "Hold flight and crouch to stop drifting up or down",

	fuel_system = "Fuel", fuel_sub = "Flying uses fuel. Standing on the ground refills it.",
	tank = "Tank size", tank_sub = "How many seconds you can fly",
	refill_time = "Refill speed", refill_time_sub = "Seconds to fill an empty tank",
	refill_delay = "Refill wait", refill_delay_sub = "Seconds on the ground before refilling starts",
	boost = "Boost", boost_sub = "Press the boost key while flying for a quick burst",
	boost_cd = "Boost cooldown", boost_cd_sub = "Seconds before you can boost again",
	boost_cost = "Boost fuel cost", boost_cost_sub = "Fuel used per boost (needs Fuel on)",
	upgrades = "Upgrades", upgrades_sub = "Fly more to unlock bigger tank, thrust and refill",

	approval = "Approval mode", approval_on_sub = "Only players marked Can fly can use the jetpack",
	approval_off_sub = "Everyone can fly. Blocking a player turns approval mode on.",
	allow_all = "Allow all", block_all = "Block all",
	can_fly = "Can fly", blocked = "Blocked", host = "Host", refill = "Refill",
	row_peak = "Peak %s", row_thrust = "Thrust", row_fuel = "Endurance", reset = "Reset",

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

	flight_key = "Flight key",
	key_sub_kb = "Click the button, then press a key",
	key_sub_pad = "Pick the action that makes you fly",
	press_key = "Press a key...", clear = "Clear", kb_only = "Keyboard only",
	key_in_use = "That key is already used for flying, boost or the menu",
	boost_key = "Boost key", boost_key_sub = "Press it while flying for a short burst",
	menu_key = "Menu key", menu_key_sub = "Open and close this menu without pausing", menu_key_none = "Not set",
	effects = "Exhaust effects", effects_sub = "Flames and smoke behind jetpacks",
	fx_off = "Off", fx_light = "Flames", fx_full = "Full",
	accent = "Accent colour", accent_sub = "Buttons and highlights",
	flame = "Flame colour", flame_sub = "Colour of your exhaust flames",
	flame_orange = "Orange", flame_blue = "Blue", flame_green = "Green", flame_purple = "Purple", flame_pink = "Pink",
	last_tab = "Reopen on last tab", last_tab_sub = "Open this menu where you left it",
	reset_personal = "Reset my settings", reset_personal_sub = "Keys, effects, colours and HUD. Host settings stay.",
	toast_personal_reset = "Personal settings reset",

	gauge = "Auto-hide fuel gauge", gauge_sub = "Fade the gauge out after a few seconds on the ground",
	speed_hud = "Speed readout", speed_hud_sub = "Show your current speed on screen",
	alt_hud = "Altitude readout", alt_hud_sub = "Show your height above the ground",
	speed_unit = "Speed unit", unit_ms = "m/s", unit_kmh = "km/h", unit_mph = "mph",
	gauge_size = "Gauge size", size_s = "Small", size_m = "Medium", size_l = "Large",
	gauge_pos = "Gauge position", pos_bottom = "Bottom", pos_top = "Top", pos_left = "Left", pos_right = "Right",
	gauge_color = "Gauge colour", gc_accent = "Accent", gc_cb = "Colourblind", gc_green = "Green",
	gc_cyan = "Cyan", gc_white = "White",

	stat_peak = "PEAK HEIGHT", stat_peak_sub = "above take-off",
	stat_dist = "DISTANCE FLOWN", stat_dist_sub = "all time",
	stat_time = "FLIGHT TIME", stat_boosts = "%d boosts",
	up_title = "Upgrades", up_off = "Off - turn them on under Fuel & Boost",
	up_tier = "Tier %d   +%d%%", up_locked = "Locked", up_max = "MAX",
	pilots = "Pilots", pilots_more = "Pilots (+%d more)",
	col_peak = "PEAK", col_dist = "DISTANCE", col_time = "TIME",

	about_name = "Jetpack (Multiplayer)", about_based = "Based on the built-in Jetpack by Tuxedo Labs.",
	about_revision = "Revision %d", changelog = "Changelog",

	hud_fuel = "FUEL  %.1fs", hud_empty = "FUEL EMPTY",
	boost_ready = "BOOST READY", boost_wait = "BOOST  %ds", alt_value = "ALT %d m",

	act_jump = "Jump", act_crouch = "Crouch", act_interact = "Interact",
	act_flashlight = "Flashlight", act_grab = "Grab", act_usetool = "Use tool",
	key_space = "Space", key_shift = "Shift", key_ctrl = "Ctrl", key_alt = "Alt",
	key_tab = "Tab", key_rmb = "Right click", key_mmb = "Middle click",
}

-- single player wording, used instead of the above
local SP_STRINGS = {
	host_view = "Single player",
	sec_game = "Jetpack", sec_host = "Tools", sec_you = "Personal", tab_admin = "Tools",
	jetpack_sub = "Turn the jetpack on or off",
	upgrades_sub = "Fly more to unlock a bigger tank, thrust and refill",
	host_free_sub = "You never run out of fuel. Resets when you leave.",
	refill_all = "Refill tank", toast_refilled = "Your tank is full",
	toast_all_reset = "All jetpack settings reset",
	reset_personal_sub = "Keys, effects, colours and HUD.",
}

-- client state, all in one table
local K = {
	sp = false, open = false, openedAt = 0, tab = "flight", lastTab = "flight", remember = true,
	quickKey = "", kb = "jump", pad = "jump", boostKb = "q", boostPad = "interact",
	capturing = false, captureTarget = "fly", captureStart = 0, bindTimer = BIND_RESEND, wasPad = false,
	localFuel = nil, lastFuelOn = false,
	autoHide = true, gaugeAlpha = 1, groundTime = 0, gaugeSize = 2, gaugePos = 1, gaugeColor = 1,
	speedHud = false, speedShown = 0, speedUnit = 1, altHud = false, altShown = 0, altGroundY = nil,
	fx = 2, flame = FLAME_DEFAULT, toastText = "", toastUntil = 0, noteText = "", noteUntil = 0, lastNoteSeq = nil,
	boostCd = 0, wasBoosting = false, page = 1, armedId = nil, armedUntil = 0, aboutIdx = 1,
	accent = ACCENT_DEFAULT, snd = 0,
}

local TABS = {}
local pending = {}
local LEGACY_TABS = {
	general = "flight", modes = "flight", extras = "fuel", personal = "controls", comfort = "controls",
	host = "admin", access = "admin",
}
local PAD_ACTIONS = { "jump", "crouch", "interact", "flashlight", "grab" }
local PAD_VALID = {}
for _, name in ipairs(PAD_ACTIONS) do PAD_VALID[name] = true end
local SPEED_FACTOR = { 1, 3.6, 2.23694 }
local SPEED_UNIT_KEYS = { "unit_ms", "unit_kmh", "unit_mph" }

local function T(key, ...)
	local text = (K.sp and SP_STRINGS[key]) or STRINGS[key] or key
	if select("#", ...) > 0 then
		local ok, out = pcall(string.format, text, ...)
		if ok then return out end
	end
	return text
end

local function fmtDist(m)
	if m >= 1000 then return string.format("%.2f km", m / 1000) end
	return string.format("%d m", floor(m))
end

local function fmtTime(s)
	s = floor(s)
	if s >= 3600 then
		return string.format("%d:%02d:%02d", floor(s / 3600), floor((s % 3600) / 60), s % 60)
	end
	return string.format("%d:%02d", floor(s / 60), s % 60)
end

local function listIndex(list, stride, pid)
	if type(list) ~= "table" then return nil end
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

local function fuelMultipliers(pid)
	local _, ovFuel = getOverrides(pid)
	local _, _, time = getStats(pid)
	local on = shared.upgrades == true
	return ovFuel / 100 * (1 + upBonus(UPGRADES[1], time, on)), 1 + upBonus(UPGRADES[3], time, on)
end

local function playerFlame(pid)
	if pid == GetLocalPlayer() then return K.flame end
	local list = shared.pf
	local i = listIndex(list, 2, pid)
	if i then return list[i + 1] end
	return FLAME_DEFAULT
end

local function listHas(list, pid)
	if type(list) ~= "table" then return false end
	for i = 1, #list do
		if list[i] == pid then return true end
	end
	return false
end

-- Server settings are shown optimistically for a moment while the server catches up.
local function setPending(key, value)
	pending[key] = { value = value, expires = GetTime() + 0.6 }
end

local function pendingValue(key, actual)
	local p = pending[key]
	if p and GetTime() < p.expires then return p.value end
	return actual
end

local function send(key, fn, value)
	setPending(key, value)
	ServerCall(fn, value)
end

local function usingPad()
	local ok, device = pcall(LastInputDevice)
	return ok and device == 2
end

local function sendBind(pad)
	K.bindTimer = 0
	ServerCall("server.setPlayerBind", GetLocalPlayer(), pad and K.pad or K.kb, pad and K.boostPad or K.boostKb, K.flame)
end

local function bindLabel(name)
	return STRINGS["act_" .. name] or STRINGS["key_" .. name] or string.upper(name)
end

local function cycleList(list, current, step)
	for i = 1, #list do
		if list[i] == current then return list[(i - 1 + step) % #list + 1] end
	end
	return list[1]
end

-- colours -------------------------------------------------------------------

local ACCENT = { 0.40, 0.90, 0.68 }
-- Accent colours are saved by position, so new ones only go at the end.
local ACCENT_PALETTE = {
	{ 1.0, 0.82, 0.18 }, { 0.35, 0.70, 0.95 }, { 0.45, 0.85, 0.55 }, { 0.95, 0.50, 0.75 },
	{ 1.0, 0.55, 0.20 }, { 0.92, 0.32, 0.32 }, { 0.68, 0.50, 0.95 }, { 0.30, 0.82, 0.78 },
	{ 0.72, 0.90, 0.25 }, { 0.92, 0.92, 0.92 }, { 0.40, 0.90, 0.68 },  -- 11 mint (default)
}
local FLAME_KEYS = { "flame_orange", "flame_blue", "flame_green", "flame_purple", "flame_pink" }
local GAUGE_KEYS = { "gc_accent", "gc_cb", "gc_green", "gc_cyan", "gc_white" }
local GAUGE_PALETTE = { false, { 0.34, 0.71, 0.91 }, { 0.45, 0.85, 0.55 }, { 0.30, 0.82, 0.90 }, { 0.95, 0.95, 0.95 } }
local GAUGE_LOW = { 0.95, 0.28, 0.24 }
local GAUGE_LOW_CB = { 0.84, 0.37, 0.0 }

local PANEL  = { 0.07, 0.07, 0.08 }
local BTN    = { 0.20, 0.20, 0.22 }
local GREEN  = { 0.25, 0.65, 0.35 }
local RED    = { 0.70, 0.27, 0.27 }
local WHITE  = { 1, 1, 1 }
local DARK   = { 0.08, 0.08, 0.08 }
local GOOD   = { 0.45, 0.85, 0.55 }
local BAD    = { 0.90, 0.45, 0.45 }
local GREY   = { 0.6, 0.6, 0.65 }
local OFF_SWITCH = { 0.32, 0.32, 0.35 }

-- personal settings (only affect this player, saved on this PC) -------------------------

local function setAccent(i, save)
	i = ACCENT_PALETTE[i] and i or ACCENT_DEFAULT  -- 0 = never chosen
	K.accent = i
	local c = ACCENT_PALETTE[i]
	ACCENT[1], ACCENT[2], ACCENT[3] = c[1], c[2], c[3]
	if save then SetInt("savegame.mod.accent", i) end
end

local function setStr(field, key, v) K[field] = v SetString(key, v) end
local function setInt(field, key, v) K[field] = v SetInt(key, v) end
local function setFlag(field, key, on, inv)
	on = on and true or false
	K[field] = on
	SetInt(key, (on ~= inv) and 1 or 0)
end

local function setKbBind(v, pad) setStr("kb", "savegame.mod.flykey", v) sendBind(pad) end
local function setPadBind(v, pad) setStr("pad", "savegame.mod.padkey", v) sendBind(pad) end
local function setBoostKb(v, pad) setStr("boostKb", "savegame.mod.boostkey", v) sendBind(pad) end
local function setBoostPad(v, pad) setStr("boostPad", "savegame.mod.boostpadkey", v) sendBind(pad) end
local function setGaugeAutoHide(on) setFlag("autoHide", "savegame.mod.hudautohideoff", on, true) end
local function setSpeedHud(on) setFlag("speedHud", "savegame.mod.speedhud", on, false) end
local function setAltHud(on) setFlag("altHud", "savegame.mod.alt_hud", on, false) K.altGroundY = nil end
local function setRememberTab(on) setFlag("remember", "savegame.mod.tab_forget", on, true) end
local function setSpeedUnit(v) setInt("speedUnit", "savegame.mod.speed_unit", SPEED_FACTOR[v] and v or 1) end
local function setFlame(i)
	setInt("flame", "savegame.mod.flame", FLAME_PALETTE[i] and i or FLAME_DEFAULT)
	sendBind(usingPad())
end
local function setGaugeSize(v) setInt("gaugeSize", "savegame.mod.gauge_size", v) end
local function setGaugePos(v) setInt("gaugePos", "savegame.mod.gauge_pos", v) end
local function setFxMode(mode) K.fx = mode % 3 SetInt("savegame.mod.fxmode", K.fx + 1) end
local function setGaugeColor(i)
	K.gaugeColor = GAUGE_PALETTE[i] ~= nil and i or 1
	SetInt("savegame.mod.gauge_cb", K.gaugeColor - 1)
end
local function setQuickKey(key) setStr("quickKey", "savegame.mod.menukey", key) end

local function startCapture(target)
	K.capturing = true
	K.captureTarget = target or "fly"
	K.captureStart = GetTime()
end

-- true when key is already used by one of the other two key settings
local function keyTaken(target, key)
	if target ~= "fly" and key == K.kb then return true end
	if target ~= "boost" and key == K.boostKb then return true end
	if target ~= "menu" and key == K.quickKey then return true end
	return false
end

local function pollCapture(pad)
	if not K.capturing or GetTime() - K.captureStart < 0.2 then return end
	local key = InputLastPressedKey()
	if key == "" or key == "lmb" then return end
	K.capturing = false
	if key == "esc" or not VALID_INPUTS[key] then return end
	local target = K.captureTarget
	if keyTaken(target, key) then
		K.toastText, K.toastUntil = T("key_in_use"), GetTime() + 3
	elseif target == "boost" then
		setBoostKb(key, pad)
	elseif target == "menu" then
		setQuickKey(key)
	else
		setKbBind(key, pad)
	end
end

local function openSettings()
	K.open = true
	K.openedAt = GetTime()
	K.tab = K.remember and K.lastTab or "flight"
	K.capturing = false
	K.page = 1
	K.armedId = nil
end

-- permissions, fuel, effects ------------------------------------------------------

local function inAllowedList(pid) return listHas(shared.allowed, pid) end

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
	if type(ids) ~= "table" or type(values) ~= "table" then return nil end
	for i = 1, #ids do
		if ids[i] == pid then return values[i] end
	end
	return nil
end

local function jitter(amount) return GetRandomFloat(-amount, amount) end

local function spawnExhaust(player, mode, boosted)
	local t = GetPlayerTransform(player)
	local origin = TransformToParentPoint(t, Vec(0, 0.85, 0.3))
	local carry = VecScale(GetPlayerVelocity(player), 0.5)
	local f = FLAME_PALETTE[playerFlame(player)] or FLAME_PALETTE[FLAME_DEFAULT]
	local down = boosted and -6 or -3.5

	for _ = 1, boosted and 5 or 2 do
		ParticleReset()
		ParticleType("plain")
		ParticleTile(5)
		if boosted then
			ParticleColor(min(1, f[1] + 0.3), min(1, f[2] + 0.3), min(1, f[3] + 0.3), f[4], f[5], f[6])
			ParticleRadius(0.13, 0.03, "easeout")
		else
			ParticleColor(f[1], f[2], f[3], f[4], f[5], f[6])
			ParticleRadius(0.07, 0.02, "easeout")
		end
		ParticleAlpha(1.0, 0.0, "easeout", 0, 0.4)
		ParticleEmissive(6, 0, "easeout")
		ParticleGravity(0)
		ParticleDrag(0.2)
		ParticleCollide(0)
		SpawnParticle(origin, VecAdd(carry, Vec(jitter(0.4), down + jitter(0.5), jitter(0.4))), 0.3)
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

	PointLight(VecAdd(origin, Vec(0, -0.4, 0)), f[4], (f[5] + f[2]) / 2, f[6], boosted and 5 or 2.5)
end

function client.init()
	K.snd = LoadLoop("jetpack.ogg")

	local v = normalizeBind(GetString("savegame.mod.flykey"))
	if v then K.kb = v end
	v = normalizeBind(GetString("savegame.mod.boostkey"))
	if v then K.boostKb = v end
	v = normalizeBind(GetString("savegame.mod.menukey"))
	if v then K.quickKey = v end
	v = GetString("savegame.mod.padkey")
	if PAD_VALID[v] then K.pad = v end
	v = GetString("savegame.mod.boostpadkey")
	if PAD_VALID[v] then K.boostPad = v end

	K.autoHide = GetInt("savegame.mod.hudautohideoff") ~= 1
	K.speedHud = GetInt("savegame.mod.speedhud") == 1
	K.altHud = GetInt("savegame.mod.alt_hud") == 1
	K.remember = GetInt("savegame.mod.tab_forget") ~= 1

	v = GetInt("savegame.mod.speed_unit")
	if SPEED_FACTOR[v] then K.speedUnit = v end

	local savedTab = GetString("savegame.mod.last_tab")
	if savedTab ~= "" then K.lastTab = LEGACY_TABS[savedTab] or savedTab end

	v = GetInt("savegame.mod.fxmode")
	if v >= 1 and v <= 3 then K.fx = v - 1 end
	v = GetInt("savegame.mod.flame")  -- 0 = never chosen, so the default (orange) applies
	if FLAME_PALETTE[v] then K.flame = v end

	v = GetInt("savegame.mod.gauge_size")
	if v >= 1 and v <= 3 then K.gaugeSize = v end
	v = GetInt("savegame.mod.gauge_pos")
	if v >= 1 and v <= 4 then K.gaugePos = v end
	v = GetInt("savegame.mod.gauge_cb") + 1
	if GAUGE_PALETTE[v] ~= nil then K.gaugeColor = v end

	setAccent(GetInt("savegame.mod.accent"), false)
end

function client.tick(dt)
	local me = GetLocalPlayer()
	local pad = usingPad()
	K.sp = GetPlayerCount() <= 1

	K.bindTimer = K.bindTimer + dt
	if K.bindTimer >= BIND_RESEND or pad ~= K.wasPad then
		K.wasPad = pad
		sendBind(pad)
	end

	if IsPlayerHost(me) or shared.menuHidden ~= true then
		if PauseMenuButton(T("title")) then openSettings() end
		if K.quickKey ~= "" and not K.capturing and InputPressed(K.quickKey) then
			if K.open then K.open = false else openSettings() end
		end
	elseif K.open then
		K.open = false
	end
	-- a key capture must never survive the menu closing, or the next key press would rebind silently
	if not K.open then K.capturing = false end
	pollCapture(pad)

	local seq = shared.noteSeq
	if seq ~= nil then
		if K.lastNoteSeq ~= nil and seq ~= K.lastNoteSeq then
			K.noteText = tostring(shared.noteText or "")
			K.noteUntil = GetTime() + 4.5
		end
		K.lastNoteSeq = seq
	end

	local health = GetPlayerHealth(me)
	local inVehicle = GetPlayerVehicle(me) ~= 0
	local tank = shared.fuelCap or FUEL_DEFAULT
	local fuelOn = shared.fuelEnabled == true and not (shared.hostFree == true and IsPlayerHost(me))

	if fuelOn ~= K.lastFuelOn then
		K.lastFuelOn = fuelOn
		K.localFuel = tank
	end
	if K.localFuel == nil or health <= 0 or K.localFuel > tank then K.localFuel = tank end

	if K.speedHud then
		local ok, vel = pcall(GetPlayerVelocity, me)
		if ok and vel then K.speedShown = K.speedShown + (VecLength(vel) - K.speedShown) * min(1, dt * 10) end
	end

	-- one position read and one ground check per tick, shared by the fuel and altitude code
	local grounded, myPos = false, nil
	if fuelOn or K.altHud then
		local ok, t = pcall(GetPlayerTransform, me)
		if ok and t then
			myPos = t.pos
			grounded = inVehicle or isGrounded(me, myPos)
		end
	end

	if K.altHud and myPos then
		local y = myPos[2]
		if K.altGroundY == nil or health <= 0 or grounded then K.altGroundY = y end
		K.altShown = K.altShown + (max(0, y - K.altGroundY) - K.altShown) * min(1, dt * 10)
	end

	local boostingList = shared.boosting
	local meBoosting = listHas(boostingList, me)
	if meBoosting and not K.wasBoosting then K.boostCd = shared.boostCd or BOOST_CD_DEFAULT end
	K.wasBoosting = meBoosting
	K.boostCd = max(0, K.boostCd - dt)

	local wantsToFly = localCanFly() and health > 0 and not inVehicle and inputHeld(pad and K.pad or K.kb)
	local flying = wantsToFly and (not fuelOn or K.localFuel > 0.02)

	if fuelOn then
		local endurance, refillMul = fuelMultipliers(me)

		if flying then
			K.localFuel = max(0, K.localFuel - dt / endurance)
		elseif grounded and K.groundTime >= (shared.refillDelay or DELAY_DEFAULT) then
			K.localFuel = min(tank, K.localFuel + dt * tank / (shared.refill or REFILL_DEFAULT) * refillMul)
		end

		local serverValue = serverFuelFor(me)
		if serverValue and math.abs(serverValue - K.localFuel) > FUEL_SNAP_DISTANCE then
			K.localFuel = serverValue
		end

		if grounded and not flying then K.groundTime = K.groundTime + dt else K.groundTime = 0 end
		-- only fade the gauge once the tank is full again
		local full = K.localFuel >= tank - 0.05
		local target = (K.autoHide and full and K.groundTime > GAUGE_HIDE_DELAY) and 0 or 1
		K.gaugeAlpha = K.gaugeAlpha + (target - K.gaugeAlpha) * min(1, dt * GAUGE_FADE_RATE)
	else
		K.groundTime = 0
		K.gaugeAlpha = 1
	end

	local camPos = GetCameraTransform().pos
	if flying then
		PlayLoop(K.snd, camPos, SOUND_VOLUME)
		if K.fx > 0 then pcall(spawnExhaust, me, K.fx, meBoosting) end
	end

	local others = shared.jetting
	if type(others) == "table" then
		for i = 1, #others do
			local p = others[i]
			if p ~= me and IsPlayerValid(p) then
				local pos = GetPlayerTransform(p).pos
				PlayLoop(K.snd, pos, SOUND_VOLUME)
				-- skip particles and lights for jetpacks too far away to notice
				if K.fx > 0 and VecLength(VecSub(pos, camPos)) < FX_RANGE then
					pcall(spawnExhaust, p, K.fx, listHas(boostingList, p))
				end
			end
		end
	end
end


-- ui toolkit ----------------------------------------------------------------------
-- Every widget is placed by its centre, relative to the current origin.
-- Header y -300..-196, body y -180..204 (sidebar left, tab content right),
-- footer y 216..300. Tab content is laid out from the top of the body down.
-- Row helpers return what was clicked instead of taking callbacks.

local PANEL_W, PANEL_H = 880, 600
local BODY_TOP, BODY_H = -180, 384
local SIDEBAR_X, SIDEBAR_W = -330, 180
local CONTENT_X, CW = 100, 630
local PAD = 20
local LEFT, RIGHT = -CW / 2 + PAD, CW / 2 - PAD
local ROW_H, ROW_STEP = 44, 48
local TAB_H, TAB_STEP, HEAD_STEP = 34, 38, 22

-- nav.items is a pool that is reused every frame; nav.n is how many entries are live this frame
local nav = { items = {}, n = 0, focus = 1, active = false, accept = false, offset = 0, offsetY = 0 }
local pressHandled = false

local function label(text, x, y, size, color, alpha, align, maxWidth)
	UiPush()
		UiTranslate(x, y)
		UiAlign(align or "center middle")
		UiFont("regular.ttf", size)
		if maxWidth then
			local width = UiGetTextSize(text)
			if width > maxWidth then
				UiFont("regular.ttf", max(11, floor(size * maxWidth / width)))
			end
		end
		UiColor(color[1], color[2], color[3], alpha or 1)
		UiText(text)
	UiPop()
end

local function isHover(x, y, w, h)
	if nav.active then return false end
	local inside
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

-- Registers a clickable area for controller focus and returns true when it is activated.
local function hit(x, y, w, h)
	local id = nav.n + 1
	nav.n = id
	local item = nav.items[id]
	if not item then
		item = {}
		nav.items[id] = item
	end
	item.x, item.y = nav.offset + x, nav.offsetY + y

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
	return min(color[1] * k, 1), min(color[2] * k, 1), min(color[3] * k, 1)
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
	-- disabled buttons are not registered, so a controller can never focus them
	if disabled then return false end
	return hit(x, y, w, h)
end

local function switch(x, y, on)
	local w, h = 60, 30
	local r, g, b = lighten(on and GREEN or OFF_SWITCH, isHover(x, y, w, h) and 1.2 or 1.0)
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

local function moveFocus(dx, dy)
	local current = nav.items[nav.focus]
	if not current or nav.focus > nav.n then nav.focus = 1 return end
	local best, bestScore
	for i = 1, nav.n do
		if i ~= nav.focus then
			local item = nav.items[i]
			local ox, oy = item.x - current.x, item.y - current.y
			local along = dx * ox + dy * oy
			if along > 4 then
				local score = along + math.abs(dx * oy - dy * ox) * 2
				if not bestScore or score < bestScore then best, bestScore = i, score end
			end
		end
	end
	if best then nav.focus = best end
end

local function handleControllerInput(tabs)
	if not nav.active then return end
	nav.focus = clamp(nav.focus, 1, max(1, nav.n))
	if InputPressed("menu_up") then moveFocus(0, -1) end
	if InputPressed("menu_down") then moveFocus(0, 1) end
	if InputPressed("menu_left") then moveFocus(-1, 0) end
	if InputPressed("menu_right") then moveFocus(1, 0) end

	local step = 0
	if InputPressed("menu_next") then step = 1 end
	if InputPressed("menu_prev") then step = -1 end
	if step ~= 0 then
		for i = 1, #tabs do
			if tabs[i].id == K.tab then
				local nextIndex = (i - 1 + step) % #tabs + 1
				K.tab = tabs[nextIndex].id
				K.capturing = false
				-- the sidebar buttons are the first nav entries, in tab order
				nav.focus = nextIndex
				break
			end
		end
	end
	if InputPressed("menu_cancel") then K.open = false end
end


-- HUD ---------------------------------------------------------------------------------

local GAUGE_SCALE = { 0.8, 1.0, 1.35 }

local function gaugeAnchor()
	local s = GAUGE_SCALE[K.gaugeSize] or 1
	local w, h = UiWidth(), UiHeight()
	local half = 103 * s
	local pos = K.gaugePos
	if pos == 2 then return w / 2, 72, s, true end
	if pos == 3 then return 24 + half, h - 72, s, false end
	if pos == 4 then return w - 24 - half, h - 72, s, false end
	return w / 2, h - 72, s, false
end

local function canShowHud(me)
	return localCanFly() and GetPlayerHealth(me) > 0 and GetPlayerVehicle(me) == 0
end

local function drawGauge()
	local me = GetLocalPlayer()
	if K.gaugeAlpha < 0.02 or not canShowHud(me) then return end
	if shared.hostFree == true and IsPlayerHost(me) then return end

	local tank = shared.fuelCap or FUEL_DEFAULT
	local current = K.localFuel or tank
	local fraction = clamp(current / tank, 0, 1)
	local a = K.gaugeAlpha
	local pulse = (fraction > 0.02 and fraction <= 0.22) and (0.7 + 0.3 * math.sin(GetTime() * 9)) or 1
	local normal = GAUGE_PALETTE[K.gaugeColor] or ACCENT
	local lowColor = K.gaugeColor == 2 and GAUGE_LOW_CB or GAUGE_LOW
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
				UiRoundedRect(max(196 * fraction, 6), 8, 4)
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
	if not canShowHud(GetLocalPlayer()) then return end
	local ax, ay, s, top = gaugeAnchor()
	local dir = top and 1 or -1
	local line = 0
	if K.speedHud then
		label(string.format("%d %s", round(K.speedShown * SPEED_FACTOR[K.speedUnit]), T(SPEED_UNIT_KEYS[K.speedUnit])),
			ax, ay + dir * 40 * s, floor(20 * s), WHITE, 0.8)
		line = 1
	end
	if K.altHud then
		label(T("alt_value", round(K.altShown)), ax, ay + dir * (40 + line * 24) * s, floor(20 * s), WHITE, 0.8)
	end
end

local function drawBoost()
	if shared.boostOn ~= true or not canShowHud(GetLocalPlayer()) then return end

	local ax, ay, s, top = gaugeAnchor()
	local dir = top and -1 or 1
	local y = ay + dir * 24 * s
	local total = max(1, shared.boostCd or BOOST_CD_DEFAULT)
	local ready = K.boostCd <= 0
	local frac = ready and 1 or (1 - K.boostCd / total)
	local c = ready and GOOD or GREY

	UiPush()
		UiTranslate(ax - 50 * s, y)
		UiAlign("left middle")
		UiColor(1, 1, 1, 0.12)
		UiRoundedRect(100 * s, 5 * s, 2.5 * s)
		UiColor(c[1], c[2], c[3], 0.9)
		UiRoundedRect(max(100 * s * frac, 5 * s), 5 * s, 2.5 * s)
	UiPop()
	label(ready and T("boost_ready") or T("boost_wait", math.ceil(K.boostCd)),
		ax, y + dir * 11 * s, floor(12 * s), c, ready and 0.9 or 0.65)
end

local function drawNote()
	local now = GetTime()
	if now >= K.noteUntil or K.noteText == "" then return end
	local a = min(1, (K.noteUntil - now) / 0.6)
	local w
	UiPush()
		UiFont("regular.ttf", 20)
		w = UiGetTextSize(K.noteText)
	UiPop()
	w = min(w, UiWidth() - 120)
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
		label(K.noteText, 10, 0, 20, WHITE, a, "center middle", UiWidth() - 140)
	UiPop()
end


-- settings rows ---------------------------------------------------------------------------

local function rowTop(n) return (n - 1) * ROW_STEP end

local function settingRow(top, title, subtitle, maxWidth, alpha)
	local cy = top + ROW_H / 2
	alpha = alpha or 1
	card(0, cy, CW, ROW_H)
	if subtitle == nil or subtitle == "" then
		label(title, LEFT, cy, 20, WHITE, alpha, "left middle", maxWidth)
	else
		label(title, LEFT, cy - 8, 20, WHITE, alpha, "left middle", maxWidth)
		label(subtitle, LEFT, cy + 11, 13, WHITE, 0.5 * alpha, "left middle", maxWidth)
	end
	return cy
end

-- returns true when the switch was clicked
local function toggleRow(top, title, subtitle, on, canEdit, alpha)
	local cy = settingRow(top, title, subtitle, canEdit and 500 or 440, alpha)
	if canEdit then return switch(RIGHT - 30, cy, on) end
	label(on and T("on") or T("off"), RIGHT, cy, 21, on and GOOD or BAD, 1, "right middle")
	return false
end

-- returns minusClicked, plusClicked
local function stepRow(top, title, subtitle, valueText, canEdit, alpha)
	alpha = alpha or 1
	local cy = settingRow(top, title, subtitle, canEdit and 380 or 400, alpha)
	if not canEdit then
		label(valueText, RIGHT, cy, 22, ACCENT, alpha, "right middle", 140)
		return false, false
	end
	local minus = button("-", RIGHT - 185, cy, 44, 32, BTN, WHITE, 24)
	label(valueText, RIGHT - 110, cy, 22, ACCENT, alpha, "center middle", 90)
	local plus = button("+", RIGHT - 35, cy, 44, 32, BTN, WHITE, 24)
	return minus, plus
end

-- returns the index of the option that was picked, or nil
local function choiceRow(top, title, subtitle, options, current, canEdit, alpha)
	local n = #options
	local w = (n == 2) and 120 or ((n == 3) and 104 or ((n == 4) and 80 or 70))
	local cy = settingRow(top, title, subtitle, CW - PAD * 2 - n * (w + 6) - 10, alpha)
	local picked
	for i = 1, n do
		local x = RIGHT - w / 2 - (n - i) * (w + 6)
		local active = (current == i)
		if button(T(options[i]), x, cy, w, 32, active and ACCENT or BTN, active and DARK or WHITE, 16, not canEdit) then
			picked = i
		end
	end
	return picked
end

-- returns the index of the swatch that was picked, or nil
local function swatchRow(top, title, subtitle, palette, current)
	local cy = settingRow(top, title, subtitle, 200)
	local n = #palette
	local picked
	for i = 1, n do
		local x = RIGHT - 15 - (n - i) * 31
		local c = palette[i]
		UiPush()
			UiTranslate(x, cy)
			UiAlign("center middle")
			if i == current then
				UiColor(1, 1, 1, 0.9)
				UiRoundedRect(28, 28, 8)
			end
			UiColor(c[1], c[2], c[3], 1)
			UiRoundedRect(23, 23, 6)
		UiPop()
		if hit(x, cy, 28, 28) then picked = i end
	end
	return picked
end

-- two clicks needed: first arms the button, second confirms. Returns true on confirm.
local function armedButton(id, text, x, y, w, h)
	local armed = (K.armedId == id) and GetTime() < K.armedUntil
	if button(armed and T("confirm_short") or text, x, y, w, h, armed and RED or BTN, WHITE, 16) then
		if armed then
			K.armedId = nil
			return true
		end
		K.armedId, K.armedUntil = id, GetTime() + 3
	end
	return false
end

local function toast(text) K.toastText, K.toastUntil = text, GetTime() + 3 end

-- number row that sends clamp(current +/- step) to the server
local function numRow(c, top, title, sub, key, fn, clampFn, current, step, text, alpha)
	local minus, plus = stepRow(top, title, sub, text, c.isHost, alpha)
	if minus or plus then send(key, fn, clampFn(current + (minus and -step or step))) end
end

-- like numRow, but stepping past the top turns the limit off (0) and "-" from off jumps to the top
local function limitRow(c, top, title, sub, key, fn, clampFn, current, lo, hi, step, text, alpha)
	local minus, plus = stepRow(top, title, sub, text, c.isHost, alpha)
	local v
	if minus then
		v = current == 0 and hi or max(lo, current - step)
	elseif plus and current ~= 0 then
		v = current + step > hi and 0 or current + step
	end
	if v then send(key, fn, clampFn(v)) end
end


-- tabs ---------------------------------------------------------------------------------------

function TABS.flight(c)
	local h = c.isHost
	local a = c.enabled and 1 or 0.5

	if toggleRow(rowTop(1), T("jetpack"), T("jetpack_sub"), c.enabled, h) then
		send("enabled", "server.setEnabled", not c.enabled)
	end
	numRow(c, rowTop(2), T("thrust"), T("thrust_sub", 50, 150), "thrust", "server.setThrustPct",
		clampThrust, c.thrust, 10, c.thrust .. "%", a)
	limitRow(c, rowTop(3), T("speed_cap"), T("speed_cap_sub"), "cap", "server.setSpeedCap",
		clampCap, c.cap, CAP_MIN, CAP_MAX, CAP_STEP, c.cap == 0 and T("speed_off") or T("speed_value", c.cap), a)
	limitRow(c, rowTop(4), T("ceiling"), T("ceiling_sub"), "ceiling", "server.setCeiling",
		clampCeiling, c.ceiling, CEIL_MIN, CEIL_MAX, CEIL_STEP,
		c.ceiling == 0 and T("speed_off") or string.format("%d m", c.ceiling), a)
	if toggleRow(rowTop(5), T("smooth"), T("smooth_sub"), c.smooth, h, a) then
		send("smooth", "server.setSmooth", not c.smooth)
	end
	if toggleRow(rowTop(6), T("hover_assist"), T("hover_assist_sub"), c.hover, h, a) then
		send("hover", "server.setHover", not c.hover)
	end
end

-- Fuel & Boost: four fuel rows, then boost, then upgrades. Dimmed rows still work.
function TABS.fuel(c)
	local h = c.isHost
	local fa = c.fuelOn and 1 or 0.5
	local ba = c.boostOn and 1 or 0.5

	if toggleRow(rowTop(1), T("fuel_system"), T("fuel_sub"), c.fuelOn, h) then
		send("fuelOn", "server.setFuelEnabled", not c.fuelOn)
	end
	numRow(c, rowTop(2), T("tank"), T("tank_sub"), "tank", "server.setFuelCap",
		clampFuel, c.tank, 1, c.tank .. " s", fa)
	numRow(c, rowTop(3), T("refill_time"), T("refill_time_sub"), "refill", "server.setRefill",
		clampRefill, c.refill, REFILL_STEP, string.format("%.1f s", c.refill), fa)
	numRow(c, rowTop(4), T("refill_delay"), T("refill_delay_sub"), "delay", "server.setRefillDelay",
		clampDelay, c.refillDelay, DELAY_STEP, string.format("%.1f s", c.refillDelay), fa)
	if toggleRow(rowTop(5), T("boost"), T("boost_sub"), c.boostOn, h) then
		send("boostOn", "server.setBoostOn", not c.boostOn)
	end
	numRow(c, rowTop(6), T("boost_cd"), T("boost_cd_sub"), "boostCd", "server.setBoostCd",
		clampBoostCd, c.boostCd, 1, string.format("%d s", c.boostCd), ba)
	numRow(c, rowTop(7), T("boost_cost"), T("boost_cost_sub"), "boostCost", "server.setBoostCost",
		clampBoostCost, c.boostCost, BOOST_COST_STEP, string.format("%.1f s", c.boostCost), ba)
	if toggleRow(rowTop(8), T("upgrades"), T("upgrades_sub"), c.upgrades, h) then
		send("upgrades", "server.setUpgrades", not c.upgrades)
	end
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

local function byDistance(x, y)
	if x.dist ~= y.dist then return x.dist > y.dist end
	return x.p < y.p
end

function TABS.stats(c)
	local me = GetLocalPlayer()
	local peak, dist, time, boosts = getStats(me)

	statCard(-215, 48, 200, 96, STAT_COLORS[1], T("stat_peak"), fmtDist(peak), T("stat_peak_sub"))
	statCard(0, 48, 200, 96, STAT_COLORS[2], T("stat_dist"), fmtDist(dist), T("stat_dist_sub"))
	statCard(215, 48, 200, 96, STAT_COLORS[3], T("stat_time"), fmtTime(time), T("stat_boosts", boosts))

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
				if t <= tier then UiColor(ACCENT[1], ACCENT[2], ACCENT[3], a) else UiColor(1, 1, 1, 0.15) end
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
			UiRoundedRect(max(6, 250 * clamp(frac, 0, 1)), 6, 3)
		UiPop()
		local text = tier > 0 and T("up_tier", tier, round(up.bonus[tier] * 100)) or T("up_locked")
		if tier >= #up.at then text = text .. "   " .. T("up_max") end
		label(text, RIGHT, y, 15, tier > 0 and ACCENT or WHITE, tier > 0 and a or 0.5 * a, "right middle", 190)
	end

	local rows = {}
	for _, p in ipairs(GetAllPlayers()) do
		local pk, ds, tm = getStats(p)
		rows[#rows + 1] = { p = p, peak = pk, dist = ds, time = tm }
	end
	table.sort(rows, byDistance)

	local shown = min(4, #rows)
	local maxDist = 1
	for i = 1, shown do maxDist = max(maxDist, rows[i].dist) end

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
			UiRoundedRect(max(8, (CW - 24) * r.dist / maxDist), 22, 6)
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

function TABS.players(c)
	if toggleRow(rowTop(1), T("approval"), c.restrict and T("approval_on_sub") or T("approval_off_sub"),
		c.restrict, true) then
		send("restrict", "server.setRestrict", not c.restrict)
	end

	if button(T("allow_all"), -155, 72, 300, 26, GREEN, WHITE, 16, not c.restrict) then
		ServerCall("server.setAllowedAll", true)
	end
	if button(T("block_all"), 155, 72, 300, 26, RED, WHITE, 16, not c.restrict) then
		ServerCall("server.setAllowedAll", false)
	end

	local players = GetAllPlayers()
	local perPage = 3
	local pages = max(1, math.ceil(#players / perPage))
	K.page = clamp(K.page, 1, pages)
	local first = (K.page - 1) * perPage

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
		label(oT .. "%", -190, y2, 17, oT ~= 100 and ACCENT or WHITE, 0.9, "center middle", 50)
		if button("+", -152, y2, 28, 26, BTN, WHITE, 20) then stepMul(p, "thrust", oT, MUL_STEP, MUL_T_MAX) end

		label(T("row_fuel"), -122, y2, 15, WHITE, 0.5, "left middle", 74)
		if button("-", -30, y2, 28, 26, BTN, WHITE, 20) then stepMul(p, "fuel", oF, -MUL_STEP, MUL_F_MAX) end
		label(oF .. "%", 10, y2, 17, oF ~= 100 and ACCENT or WHITE, 0.9, "center middle", 50)
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
		if button("<", -60, 358, 44, 26, BTN, WHITE, 18) then K.page = (K.page - 2) % pages + 1 end
		label(K.page .. " / " .. pages, 0, 358, 17, WHITE, 0.7)
		if button(">", 60, 358, 44, 26, BTN, WHITE, 18) then K.page = K.page % pages + 1 end
	end
end

local PROFILE_BUTTONS = { "original", "balanced", "turbo", "custom1", "custom2" }
local PROFILE_LABEL = {
	original = "profile_original", balanced = "profile_balanced", turbo = "profile_turbo",
	custom1 = "custom_1", custom2 = "custom_2",
}

local function profileDef(name)
	local slot = tonumber(string.match(name, "^custom(%d)$"))
	if slot then
		local l = shared["custom" .. slot]
		if type(l) == "table" and #l == 5 then
			return { thrust = l[1], cap = l[2], smooth = l[3] == 1, fuel = l[4] == 1, tank = l[5] }
		end
		return nil
	end
	return PROFILES[name]
end

-- show a profile's values straight away while the server catches up
local function setProfilePending(p)
	setPending("thrust", p.thrust)
	setPending("cap", p.cap)
	setPending("smooth", p.smooth)
	setPending("fuelOn", p.fuel)
	setPending("tank", p.tank)
end

local function applyProfileHere(name)
	local p = profileDef(name)
	if not p then return end
	setProfilePending(p)
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

local function resetHostSettings()
	for _, key in ipairs({ "enabled", "announce", "hover", "smooth" }) do setPending(key, true) end
	for _, key in ipairs({ "menuHidden", "hostFree", "restrict", "boostOn", "upgrades" }) do setPending(key, false) end
	-- resetAll on the server applies the Original profile itself, so only the display is updated here
	setProfilePending(PROFILES.original)
	setPending("refill", REFILL_DEFAULT)
	setPending("delay", DELAY_DEFAULT)
	setPending("ceiling", 0)
	setPending("boostCd", BOOST_CD_DEFAULT)
	setPending("boostCost", BOOST_COST_DEFAULT)
	ServerCall("server.resetAll")
end

-- bottom action bar of the Admin tab
local ACTIONS = {
	{ id = "refill", text = "refill_all", needsFuel = true },
	{ id = "overrides", text = "clear_overrides", multiplayer = true },
	{ id = "stats", text = "reset_stats", armed = true },
	{ id = "all", text = "reset_all", armed = true },
}
local actionLists = {}

local function actionsFor(multiplayer)
	local list = actionLists[multiplayer]
	if list then return list end
	list = {}
	for _, a in ipairs(ACTIONS) do
		if multiplayer or not a.multiplayer then list[#list + 1] = a end
	end
	actionLists[multiplayer] = list
	return list
end

local function runAction(id)
	if id == "refill" then
		ServerCall("server.refillAll")
		toast(T("toast_refilled"))
	elseif id == "overrides" then
		ServerCall("server.resetOverrides")
		toast(T("toast_cleared"))
	elseif id == "stats" then
		ServerCall("server.resetStats")
		toast(T("toast_stats_reset"))
	elseif id == "all" then
		resetHostSettings()
		toast(T("toast_all_reset"))
	end
end

function TABS.admin(c)
	card(0, 66, CW, 132)
	label(T("profiles"), LEFT, 20, 21, WHITE, 1, "left middle", 300)
	label(T("profiles_sub"), LEFT, 41, 14, WHITE, 0.5, "left middle", CW - 40)

	local current = activeProfile(c)
	for i, name in ipairs(PROFILE_BUTTONS) do
		local active = (current == name)
		if button(T(PROFILE_LABEL[name]), (i - 3) * 120, 78, 112, 34,
			active and ACCENT or BTN, active and DARK or WHITE, 17, profileDef(name) == nil) then
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

	if toggleRow(138, T("host_free"), T("host_free_sub"), c.hostFree, true, c.fuelOn and 1 or 0.55) then
		send("hostFree", "server.setHostFree", not c.hostFree)
	end

	local y = 192
	if c.multiplayer then
		if toggleRow(192, T("menu_hidden"), T("menu_hidden_sub"), c.menuHidden, true) then
			send("menuHidden", "server.setMenuHidden", not c.menuHidden)
		end
		if toggleRow(246, T("announce"), T("announce_sub"), c.announce, true) then
			send("announce", "server.setAnnounce", not c.announce)
		end
		y = 300
	end

	local actions = actionsFor(c.multiplayer)
	local n = #actions
	local cy = y + 24
	local w = (CW - 24) / n - 8
	card(0, cy, CW, 48)
	for i, a in ipairs(actions) do
		local x = -CW / 2 + 12 + (i - 0.5) * (CW - 24) / n
		local text = T(a.text)
		local clicked
		if a.armed then
			clicked = armedButton(a.id, text, x, cy, w, 36)
		else
			clicked = button(text, x, cy, w, 36, BTN, WHITE, 16, a.needsFuel and not c.fuelOn)
		end
		if clicked then runAction(a.id) end
	end
end

local function resetPersonal()
	setGaugeAutoHide(true)
	setSpeedHud(false)
	setSpeedUnit(1)
	setAltHud(false)
	setGaugeSize(2)
	setGaugePos(1)
	setGaugeColor(1)
	-- set the saved values directly and tell the server once, instead of once per key
	setStr("kb", "savegame.mod.flykey", "jump")
	setStr("pad", "savegame.mod.padkey", "jump")
	setStr("boostKb", "savegame.mod.boostkey", "q")
	setStr("boostPad", "savegame.mod.boostpadkey", "interact")
	setFxMode(2)
	setInt("flame", "savegame.mod.flame", FLAME_DEFAULT)
	sendBind(usingPad())
	setAccent(ACCENT_DEFAULT, true)
	setQuickKey("")
	setRememberTab(true)
end

-- keyboard key button + reset button. Returns true when reset was clicked.
local function keyPicker(cy, target, current, resetKey, resetText)
	local waiting = K.capturing and K.captureTarget == target
	local text = waiting and T("press_key") or (current == "" and T("menu_key_none") or bindLabel(current))
	if button(text, 134, cy, 170, 32, waiting and ACCENT or BTN, waiting and DARK or WHITE, 18) then
		if waiting then K.capturing = false else startCapture(target) end
	end
	if button(resetText, 260, cy, 70, 32, BTN, WHITE, 15, current == resetKey) then
		K.capturing = false
		return true
	end
	return false
end

-- controller action picker. Returns the newly chosen action, or nil.
local function padPicker(cy, current)
	local chosen
	if button("<", 77, cy, 40, 32, BTN, WHITE, 22) then chosen = cycleList(PAD_ACTIONS, current, -1) end
	if button(bindLabel(current), 176, cy, 150, 32, ACCENT, DARK, 18) then chosen = cycleList(PAD_ACTIONS, current, 1) end
	if button(">", 275, cy, 40, 32, BTN, WHITE, 22) then chosen = cycleList(PAD_ACTIONS, current, 1) end
	return chosen
end

-- Everything here only affects this player and is saved on this PC.
function TABS.controls()
	local pad = nav.active
	local ba = (shared.boostOn == true) and 1 or 0.6

	local cy = settingRow(rowTop(1), T("flight_key"), pad and T("key_sub_pad") or T("key_sub_kb"), 300)
	if pad then
		local v = padPicker(cy, K.pad)
		if v then setPadBind(v, true) end
	elseif keyPicker(cy, "fly", K.kb, "jump", T("reset")) then
		setKbBind("jump", false)
	end

	cy = settingRow(rowTop(2), T("boost_key"), T("boost_key_sub"), 300, ba)
	if pad then
		local v = padPicker(cy, K.boostPad)
		if v then setBoostPad(v, true) end
	elseif keyPicker(cy, "boost", K.boostKb, "q", T("reset")) then
		setBoostKb("q", false)
	end

	cy = settingRow(rowTop(3), T("menu_key"), T("menu_key_sub"), 300)
	if pad then
		label(T("kb_only"), RIGHT, cy, 18, WHITE, 0.5, "right middle", 200)
	elseif keyPicker(cy, "menu", K.quickKey, "", T("clear")) then
		setQuickKey("")
	end

	local pick = choiceRow(rowTop(4), T("effects"), T("effects_sub"), { "fx_off", "fx_light", "fx_full" }, K.fx + 1, true)
	if pick then setFxMode(pick - 1) end

	pick = choiceRow(rowTop(5), T("flame"), T("flame_sub"), FLAME_KEYS, K.flame, true)
	if pick then setFlame(pick) end

	pick = swatchRow(rowTop(6), T("accent"), T("accent_sub"), ACCENT_PALETTE, K.accent)
	if pick then setAccent(pick, true) end

	if toggleRow(rowTop(7), T("last_tab"), T("last_tab_sub"), K.remember, true) then
		setRememberTab(not K.remember)
	end

	cy = settingRow(rowTop(8), T("reset_personal"), T("reset_personal_sub"), 330)
	if armedButton("personal", T("reset"), RIGHT - 90, cy, 180, 32) then
		resetPersonal()
		toast(T("toast_personal_reset"))
	end
end

function TABS.hud()
	if toggleRow(rowTop(1), T("gauge"), T("gauge_sub"), K.autoHide, true) then setGaugeAutoHide(not K.autoHide) end
	if toggleRow(rowTop(2), T("speed_hud"), T("speed_hud_sub"), K.speedHud, true) then setSpeedHud(not K.speedHud) end
	if toggleRow(rowTop(3), T("alt_hud"), T("alt_hud_sub"), K.altHud, true) then setAltHud(not K.altHud) end

	local pick = choiceRow(rowTop(4), T("speed_unit"), nil, SPEED_UNIT_KEYS, K.speedUnit, true, K.speedHud and 1 or 0.5)
	if pick then setSpeedUnit(pick) end

	pick = choiceRow(rowTop(5), T("gauge_size"), nil, { "size_s", "size_m", "size_l" }, K.gaugeSize, true)
	if pick then setGaugeSize(pick) end

	pick = choiceRow(rowTop(6), T("gauge_pos"), nil, { "pos_bottom", "pos_top", "pos_left", "pos_right" }, K.gaugePos, true)
	if pick then setGaugePos(pick) end

	pick = choiceRow(rowTop(7), T("gauge_color"), nil, GAUGE_KEYS, K.gaugeColor, true)
	if pick then setGaugeColor(pick) end
end

-- About: name, version and the changelog (newest entry first, arrows step through older ones).
function TABS.about()
	local n = #CHANGELOG
	K.aboutIdx = clamp(K.aboutIdx, 1, n)
	local entry = CHANGELOG[K.aboutIdx]

	card(0, 40, CW, 80)
	label(T("about_name"), LEFT, 24, 24, WHITE, 1, "left middle", 340)
	label(T("about_based"), LEFT, 56, 14, WHITE, 0.55, "left middle", 340)
	label("v" .. VERSION, RIGHT, 24, 24, ACCENT, 1, "right middle", 200)
	label(T("about_revision", REVISION), RIGHT, 56, 15, WHITE, 0.55, "right middle", 200)

	card(0, 235, CW, 290)
	label(T("changelog"), LEFT, 112, 20, WHITE, 1, "left middle", 200)
	if n > 1 then
		if button("<", 130, 112, 36, 26, BTN, WHITE, 18) then K.aboutIdx = (K.aboutIdx - 2) % n + 1 end
		label(entry.version .. "  (" .. K.aboutIdx .. "/" .. n .. ")", 205, 112, 15, WHITE, 0.8, "center middle", 88)
		if button(">", 277, 112, 36, 26, BTN, WHITE, 18) then K.aboutIdx = K.aboutIdx % n + 1 end
	end

	UiPush()
		UiTranslate(0, 132)
		UiAlign("center middle")
		UiColor(1, 1, 1, 0.10)
		UiRect(CW - 40, 2)
	UiPop()

	label(entry.version .. "  -  " .. entry.title, LEFT, 152, 17, ACCENT, 1, "left middle", CW - 40)
	for i, line in ipairs(entry.notes) do
		local y = 178 + (i - 1) * 21
		UiPush()
			UiTranslate(LEFT + 4, y)
			UiAlign("center middle")
			UiColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.8)
			UiRoundedRect(5, 5, 2.5)
		UiPop()
		label(line, LEFT + 16, y, 14, WHITE, 0.8, "left middle", CW - 56)
	end
end


-- settings window ---------------------------------------------------------------------------

local tabCache = {}

-- About is always the last tab and is drawn pinned to the bottom of the sidebar.
local function buildTabs(isHost, multiplayer)
	local cacheKey = (isHost and 1 or 0) + (multiplayer and 2 or 0)
	local tabs = tabCache[cacheKey]
	if tabs then return tabs end

	tabs = {
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
	tabs[#tabs + 1] = { id = "about", name = T("tab_about"), bottom = true }
	tabCache[cacheKey] = tabs
	return tabs
end

local function drawHeader(c)
	label(T("title"), -400, -262, 34, WHITE, 1, "left middle", 420)
	if GetTime() < K.toastUntil then
		label(K.toastText, -400, -226, 17, ACCENT, 1, "left middle", 460)
	elseif c.blocked then
		label(T("not_allowed"), -400, -226, 17, BAD, 1, "left middle", 460)
	else
		local subtitle = c.isHost and T("host_view") or T("player_view")
		if c.multiplayer then subtitle = subtitle .. "   -   " .. T("host_stats", c.playerCount, c.flyingCount) end
		label(subtitle, -400, -226, 17, WHITE, 0.5, "left middle", 460)
	end

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

local function drawSidebar(tabs)
	card(SIDEBAR_X, BODY_TOP + BODY_H / 2, SIDEBAR_W, BODY_H)
	local y, section = BODY_TOP + 6, nil
	for i = 1, #tabs do
		local entry = tabs[i]
		local cy
		if entry.bottom then
			cy = BODY_TOP + BODY_H - 6 - TAB_H / 2
			UiPush()
				UiTranslate(SIDEBAR_X, cy - TAB_H / 2 - 4)
				UiAlign("center middle")
				UiColor(1, 1, 1, 0.10)
				UiRect(SIDEBAR_W - 24, 1)
			UiPop()
		else
			if entry.section ~= section then
				section = entry.section
				label(string.upper(T(section)), SIDEBAR_X - (SIDEBAR_W - 24) / 2 + 4, y + HEAD_STEP / 2, 13, WHITE, 0.4, "left middle")
				y = y + HEAD_STEP
			end
			cy = y + TAB_H / 2
			y = y + TAB_STEP
		end
		local active = (K.tab == entry.id)
		if button(entry.name, SIDEBAR_X, cy, SIDEBAR_W - 24, TAB_H,
			active and ACCENT or BTN, active and DARK or WHITE, 19) then
			K.tab = entry.id
			K.capturing = false
		end
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
	elseif not isHost and (K.tab == "flight" or K.tab == "fuel") then
		text = T("host_only_note")
	end
	label(text, -400, 258, 15, WHITE, 0.45, "left middle", 560)
	if button(T("close"), 325, 258, 150, 42, ACCENT, DARK, 24) then K.open = false end
end

local function drawWindow()
	UiMakeInteractive()

	local me = GetLocalPlayer()
	local isHost = IsPlayerHost(me)
	local playerCount = GetPlayerCount()
	local multiplayer = playerCount > 1

	nav.active = usingPad()
	nav.accept = nav.active and InputPressed("menu_accept") and GetTime() - K.openedAt > 0.2
	nav.n = 0

	local jetting = shared.jetting
	local c = {
		isHost = isHost,
		multiplayer = multiplayer,
		playerCount = playerCount,
		flyingCount = type(jetting) == "table" and #jetting or 0,
		enabled = pendingValue("enabled", shared.enabled ~= false),
		thrust = pendingValue("thrust", shared.thrustPct or THRUST_DEFAULT),
		smooth = pendingValue("smooth", shared.smooth ~= false),
		cap = pendingValue("cap", shared.speedCap or 0),
		fuelOn = pendingValue("fuelOn", shared.fuelEnabled == true),
		tank = pendingValue("tank", shared.fuelCap or FUEL_DEFAULT),
		refill = pendingValue("refill", shared.refill or REFILL_DEFAULT),
		refillDelay = pendingValue("delay", shared.refillDelay or DELAY_DEFAULT),
		hover = pendingValue("hover", shared.hover ~= false),
		boostOn = pendingValue("boostOn", shared.boostOn == true),
		boostCd = pendingValue("boostCd", shared.boostCd or BOOST_CD_DEFAULT),
		boostCost = pendingValue("boostCost", shared.boostCost or BOOST_COST_DEFAULT),
		upgrades = pendingValue("upgrades", shared.upgrades == true),
		ceiling = pendingValue("ceiling", shared.ceiling or 0),
		hostFree = pendingValue("hostFree", shared.hostFree == true),
		restrict = pendingValue("restrict", shared.restrict == true),
		menuHidden = pendingValue("menuHidden", shared.menuHidden == true),
		announce = pendingValue("announce", shared.announce ~= false),
		blocked = (shared.restrict == true) and not isHost and not inAllowedList(me),
	}

	local tabs = buildTabs(isHost, multiplayer)
	local known = false
	for i = 1, #tabs do
		if tabs[i].id == K.tab then known = true break end
	end
	if not known then K.tab = "flight" end
	if K.tab ~= K.lastTab then
		K.lastTab = K.tab
		SetString("savegame.mod.last_tab", K.tab)
	end

	UiPush()
		UiColor(0, 0, 0, 0.55)
		UiRect(UiWidth(), UiHeight())

		UiTranslate(UiCenter(), UiMiddle())
		local fit = min(1, (UiHeight() - 24) / PANEL_H, (UiWidth() - 24) / PANEL_W)
		if fit < 1 then UiScale(fit) end
		UiAlign("center middle")

		UiColor(0, 0, 0, 0.35)
		UiRoundedRect(PANEL_W + 28, PANEL_H + 28, 32)
		UiColor(1, 1, 1, 0.10)
		UiRoundedRect(PANEL_W + 4, PANEL_H + 4, 22)
		UiColor(PANEL[1], PANEL[2], PANEL[3], 0.98)
		UiRoundedRect(PANEL_W, PANEL_H, 20)

		nav.offset, nav.offsetY = 0, 0
		drawHeader(c)
		drawSidebar(tabs)

		UiPush()
			UiTranslate(CONTENT_X, BODY_TOP)
			nav.offset, nav.offsetY = CONTENT_X, BODY_TOP
			-- a broken tab never takes the whole menu down
			local ok, err = pcall(TABS[K.tab] or TABS.flight, c)
			if not ok then label("Tab error: " .. tostring(err), 0, 40, 16, BAD, 1, "center middle", CW - 20) end
		UiPop()
		nav.offset, nav.offsetY = 0, 0

		drawFooter(isHost)
	UiPop()

	drawNote()
	handleControllerInput(tabs)

	-- a press that never became a release must not swallow the next real click
	if not InputDown("lmb") then pressHandled = false end
end

function client.draw()
	if not K.open then
		if shared.fuelEnabled then drawGauge() end
		if K.speedHud or K.altHud then drawSpeed() end
		drawBoost()
		drawNote()
		return
	end
	drawWindow()
end

end

buildClient()
