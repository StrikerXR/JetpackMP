#version 2

-- Jetpack (Multiplayer)
-- Based on the built-in Jetpack by Tuxedo Labs.
--
-- The server does the actual flying (thrust, fuel, limits). Clients handle
-- sound, exhaust effects, the fuel gauge and the settings screen.
-- Saved settings live under savegame.mod.* and keep their names between
-- versions so nobody loses their setup on update.
--
-- 28.4: stability rewrite.
--   * Flight modes (Classic / Hover / Glide) removed. Hover assist stays.
--   * All server and client state now lives in a few tables. The old script
--     used too many local variables inside one function (Lua allows 60),
--     which could stop the script loading and made every toggle say the
--     server function was not recognized.
--   * Server calls are wrapped so a bad call can never crash the menu.
--   * Fuel tab simplified, single player gets its own wording and
--     hides host-only options.
--   * More colours: 10 accent colours, 5 flame colours, 5 gauge colours.
--   * Every setting from 28.3 is still here and keeps its saved name.

local VERSION = "28.4"
local REVISION = 1

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

local MUL_MIN, MUL_STEP, MUL_T_MAX, MUL_F_MAX = 25, 25, 200, 400


-- shared helpers ------------------------------------------------------

local function num(v, default)
	v = tonumber(v)
	if v == nil or v ~= v then return default end
	return v
end

local function snap(v, step) return math.floor(v / step + 0.5) * step end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function clampThrust(v) return clamp(snap(num(v, THRUST_DEFAULT), 10), 50, 150) end
local function clampFuel(v) return clamp(math.floor(num(v, FUEL_DEFAULT) + 0.5), FUEL_MIN, FUEL_MAX) end

local function clampCap(v)
	v = num(v, 0)
	if v <= 0 then return 0 end
	return clamp(snap(v, CAP_STEP), CAP_MIN, CAP_MAX)
end

local function clampRefill(v) return clamp(snap(num(v, REFILL_DEFAULT), REFILL_STEP), REFILL_MIN, REFILL_MAX) end
local function clampDelay(v) return clamp(snap(num(v, DELAY_DEFAULT), DELAY_STEP), DELAY_MIN, DELAY_MAX) end

local function clampCeiling(v)
	v = num(v, 0)
	if v <= 0 then return 0 end
	return clamp(snap(v, CEIL_STEP), CEIL_MIN, CEIL_MAX)
end

local function clampMul(v, hi) return clamp(snap(num(v, 100), MUL_STEP), MUL_MIN, hi) end

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
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

local function isGrounded(p)
	local ok, result = pcall(function()
		if not IsPlayerValid(p) then return false end
		local pos = GetPlayerTransform(p).pos
		local hit, dist = QueryRaycast(Vec(pos[1], pos[2] + 0.25, pos[3]), Vec(0, -1, 0), 0.4)
		return hit and dist <= 0.4
	end)
	return ok and result == true
end

local function rampPower(held)
	local s = math.min(1, held / RAMP_SECONDS)
	return RAMP_FLOOR + (1 - RAMP_FLOOR) * s * s * (3 - 2 * s)
end

local function capSpeed(oldVel, newVel, cap)
	if cap <= 0 then return newVel end
	local newSpeed = VecLength(newVel)
	local limit = math.max(cap, VecLength(oldVel))
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
for c = string.byte("a"), string.byte("z") do VALID_INPUTS[string.char(c)] = true end
for d = 0, 9 do VALID_INPUTS[tostring(d)] = true end
for f = 1, 12 do VALID_INPUTS["f" .. f] = true end

local LEGACY_INPUTS = { sprint = "shift" }

local function normalizeBind(bind)
	if type(bind) ~= "string" then return nil end
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


do  -- server scope

-- Everything the server remembers sits in two tables (S settings, R per-player).
local S = {
	on = true, thrust = THRUST_DEFAULT, cap = 0, smooth = true,
	restrict = false, fuelOn = false, tank = FUEL_DEFAULT, refill = REFILL_DEFAULT,
	delay = DELAY_DEFAULT, ceiling = 0, hostFree = false,
	hover = true,
	upgrades = false, menuHidden = false, announce = true,
	noteSeq = 0, playerCount = 0, errorShown = false,
	fuelTimer = 0, statsTimer = 0, saveTimer = 0,
	lastJetting = {}, lastFuelValues = {}, lastStats = {},
}
local R = {
	allowed = {}, binds = {}, fuel = {}, ramp = {}, baseY = {}, groundedFor = {},
	ovT = {}, ovF = {},
	stats = {}, airborne = {}, lastX = {}, lastZ = {},
}

local function notify(text, force)
	if not S.announce and not force then return end
	S.noteSeq = S.noteSeq + 1
	shared.noteText = text
	shared.noteSeq = S.noteSeq
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
	shared.allowed = list
end

local function publishFuel(force)
	local ids, values = {}, {}
	local players = GetAllPlayers()
	for i = 1, #players do
		local p = players[i]
		ids[i] = p
		values[i] = math.floor((R.fuel[p] or S.tank) * 10 + 0.5) / 10
	end
	if force or not sameList(values, S.lastFuelValues) or #ids ~= #(shared.fuelIds or {}) then
		shared.fuelIds = ids
		shared.fuelVals = values
		S.lastFuelValues = values
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
	shared.pm = list
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
		time = GetInt(key .. ".time"),
	}
	R.stats[p] = s
	return s
end

local function saveStat(s)
	if not s or not s.dirty then return end
	s.dirty = false
	SetInt(s.key .. ".peak", math.floor(s.peak))
	SetInt(s.key .. ".dist", math.floor(s.dist))
	SetInt(s.key .. ".time", math.floor(s.time))
end

local function publishStats(force)
	local list = {}
	for _, p in ipairs(GetAllPlayers()) do
		local s = R.stats[p]
		if s then
			local i = #list
			list[i + 1] = p
			list[i + 2] = math.floor(s.peak)
			list[i + 3] = math.floor(s.dist)
			list[i + 4] = math.floor(s.time)
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
end

local function canFly(p)
	if not S.on then return false end
	if S.restrict and not IsPlayerHost(p) and not R.allowed[p] then return false end
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
	S.menuHidden = GetInt("savegame.mod.menu_hidden") == 1
	S.announce = GetInt("savegame.mod.quiet") ~= 1
	S.on = GetInt("savegame.mod.disabled") ~= 1
	S.smooth = GetInt("savegame.mod.noramp") ~= 1
	S.cap = clampCap(GetInt("savegame.mod.speedcap"))

	local savedThrust = GetInt("savegame.mod.thrustpct")
	if savedThrust > 0 then S.thrust = clampThrust(savedThrust) end

	S.fuelOn = GetInt("savegame.mod.fuel_enabled") == 1
	local savedTank = GetInt("savegame.mod.fuel_cap")
	S.tank = savedTank > 0 and clampFuel(savedTank) or FUEL_DEFAULT

	local savedRefill = GetInt("savegame.mod.refill_x10")
	if savedRefill > 0 then S.refill = clampRefill(savedRefill / 10) end

	S.delay = clampDelay(GetInt("savegame.mod.refill_delay_x10") / 10)
	S.ceiling = clampCeiling(GetInt("savegame.mod.ceiling"))

	S.hover = GetInt("savegame.mod.hover_off") ~= 1
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

	shared.thrustPct = S.thrust
	shared.enabled = S.on
	shared.menuHidden = S.menuHidden
	shared.announce = S.announce
	shared.speedCap = S.cap
	shared.smooth = S.smooth
	shared.fuelEnabled = S.fuelOn
	shared.fuelCap = S.tank
	shared.refill = S.refill
	shared.refillDelay = S.delay
	shared.ceiling = S.ceiling
	shared.hostFree = false
	shared.fuelIds = {}
	shared.fuelVals = {}
	shared.restrict = false
	shared.allowed = {}
	shared.jetting = {}
	shared.hover = S.hover
	shared.upgrades = S.upgrades
	shared.pm = {}
	shared.ps = {}
	shared.noteSeq = 0
	shared.noteText = ""
end

-- Everything below is called from the host's settings screen. The server
-- clamps every value itself, whatever the client sent.

function server.setThrustPct(pct)
	S.thrust = clampThrust(pct)
	shared.thrustPct = S.thrust
	SetInt("savegame.mod.thrustpct", S.thrust)
end

function server.setEnabled(on)
	S.on = on and true or false
	shared.enabled = S.on
	SetInt("savegame.mod.disabled", S.on and 0 or 1)
end

function server.setMenuHidden(on, silent)
	S.menuHidden = on and true or false
	shared.menuHidden = S.menuHidden
	SetInt("savegame.mod.menu_hidden", S.menuHidden and 1 or 0)
	if silent ~= true then
		notify(S.menuHidden and "Host hid the Jetpack settings menu" or "Host showed the Jetpack settings menu", true)
	end
end

function server.setAnnounce(on, silent)
	if not on and silent ~= true then notify("Host turned settings messages off", true) end
	S.announce = on and true or false
	shared.announce = S.announce
	SetInt("savegame.mod.quiet", S.announce and 0 or 1)
	if S.announce and silent ~= true then notify("Host turned settings messages on") end
end

function server.setSpeedCap(cap)
	S.cap = clampCap(cap)
	shared.speedCap = S.cap
	SetInt("savegame.mod.speedcap", S.cap)
end

function server.setSmooth(on)
	S.smooth = on and true or false
	shared.smooth = S.smooth
	SetInt("savegame.mod.noramp", S.smooth and 0 or 1)
end

function server.setFuelEnabled(on)
	S.fuelOn = on and true or false
	shared.fuelEnabled = S.fuelOn
	SetInt("savegame.mod.fuel_enabled", S.fuelOn and 1 or 0)
	R.fuel = {}
	S.lastFuelValues = {}
	shared.fuelIds = {}
	shared.fuelVals = {}
	if S.fuelOn then publishFuel(true) end
end

function server.setFuelCap(cap)
	S.tank = clampFuel(cap)
	shared.fuelCap = S.tank
	SetInt("savegame.mod.fuel_cap", S.tank)
	for pid, amount in pairs(R.fuel) do
		if amount > S.tank then R.fuel[pid] = S.tank end
	end
end

function server.setRestrict(on)
	S.restrict = on and true or false
	shared.restrict = S.restrict
	publishAllowed()
end

function server.setAllowed(pid, on)
	if type(pid) ~= "number" or not IsPlayerValid(pid) then return end
	R.allowed[pid] = on and true or nil
	publishAllowed()
end

function server.setAllowedAll(on)
	for _, p in ipairs(GetAllPlayers()) do
		if not IsPlayerHost(p) then R.allowed[p] = on and true or nil end
	end
	publishAllowed()
end

function server.setRefill(seconds)
	S.refill = clampRefill(seconds)
	shared.refill = S.refill
	SetInt("savegame.mod.refill_x10", math.floor(S.refill * 10 + 0.5))
end

function server.setRefillDelay(seconds)
	S.delay = clampDelay(seconds)
	shared.refillDelay = S.delay
	SetInt("savegame.mod.refill_delay_x10", math.floor(S.delay * 10 + 0.5))
end

function server.setCeiling(metres)
	S.ceiling = clampCeiling(metres)
	shared.ceiling = S.ceiling
	SetInt("savegame.mod.ceiling", S.ceiling)
end

function server.setHostFree(on)
	S.hostFree = on and true or false
	shared.hostFree = S.hostFree
end

function server.refillAll()
	if not S.fuelOn then return end
	for _, p in ipairs(GetAllPlayers()) do R.fuel[p] = S.tank end
	publishFuel(true)
end

function server.refillPlayer(pid)
	if not S.fuelOn or type(pid) ~= "number" or not IsPlayerValid(pid) then return end
	R.fuel[pid] = S.tank
	publishFuel(true)
end

function server.setPlayerFlight(pid, on)
	if type(pid) ~= "number" or not IsPlayerValid(pid) or IsPlayerHost(pid) then return end
	if on then
		R.allowed[pid] = true
	else
		if not S.restrict then
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
		s.peak, s.dist, s.time = 0, 0, 0
		s.dirty = true
		saveStat(s)
	end
	publishStats(true)
	notify("Host reset flight stats")
end

function server.setHover(on)
	S.hover = on and true or false
	shared.hover = S.hover
	SetInt("savegame.mod.hover_off", S.hover and 0 or 1)
end

function server.setUpgrades(on)
	S.upgrades = on and true or false
	shared.upgrades = S.upgrades
	SetInt("savegame.mod.upgrades_on", S.upgrades and 1 or 0)
	notify(S.upgrades and "Host turned upgrades on" or "Host turned upgrades off")
end

function server.setPlayerMul(pid, kind, pct)
	if type(pid) ~= "number" or not IsPlayerValid(pid) then return end
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
	slot = math.floor(num(slot, 0))
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
	server.setUpgrades(false)
	R.ovT, R.ovF = {}, {}
	publishMuls()
	R.allowed = {}
	server.setRestrict(false)
	notify("Host reset all Jetpack settings")
end

function server.setPlayerBind(pid, bind)
	if type(pid) ~= "number" or not IsPlayerValid(pid) then return end
	bind = normalizeBind(bind)
	if bind then R.binds[pid] = bind end
end

function server.tick(dt)
	pcall(function()
		local count = GetPlayerCount()
		if count ~= S.playerCount then
			S.playerCount = count
			forgetLeftPlayers()
		end
	end)
end

-- One player, one physics step. Split out so stepPlayers stays small.
local function stepOne(p, dt, flying)
	local s = statsFor(p)
	local health = GetPlayerHealth(p)
	local inVehicle = GetPlayerVehicle(p) ~= 0
	local free = S.hostFree and IsPlayerHost(p)
	local fuel = R.fuel

	if S.fuelOn then
		if fuel[p] == nil or health <= 0 or free then
			fuel[p] = S.tank
		elseif fuel[p] > S.tank then
			fuel[p] = S.tank
		end
	end

	local endurance = (R.ovF[p] or 100) / 100 * (1 + upBonus(UPGRADES[1], s.time, S.upgrades))
	local thrustMul = (R.ovT[p] or 100) / 100 * (1 + upBonus(UPGRADES[2], s.time, S.upgrades))
	local refillMul = 1 + upBonus(UPGRADES[3], s.time, S.upgrades)

	local wantsToFly = canFly(p) and health > 0 and not inVehicle and inputHeld(R.binds[p] or "jump", p)
	local hasFuel = not S.fuelOn or free or (fuel[p] or 0) > 0.02
	local flyingNow = wantsToFly and hasFuel

	local pos = GetPlayerTransform(p).pos
	local grounded = inVehicle or isGrounded(p)

	if grounded or health <= 0 or R.baseY[p] == nil then R.baseY[p] = pos[2] end
	local ceilRoom = nil
	if S.ceiling > 0 then ceilRoom = S.ceiling - (pos[2] - R.baseY[p]) end

	if flyingNow then
		R.groundedFor[p] = 0
		R.ramp[p] = (R.ramp[p] or 0) + dt
		s.time = s.time + dt
		s.dirty = true

		local power = S.smooth and rampPower(R.ramp[p]) or 1

		local t = THRUST_BASE * S.thrust / 100 * thrustMul * power
		local vel = GetPlayerVelocity(p)
		local push = TransformToParentVec(GetPlayerCameraTransform(p), Vec(0, t, 0))

		local assist = S.hover and inputHeld("crouch", p)
		if assist then push = Vec(push[1], 0, push[3]) end

		local newVel = capSpeed(vel, VecAdd(vel, push), S.cap)
		if assist then
			-- Pull vertical speed towards what cancels the next step of gravity.
			local vy = newVel[2]
			newVel = Vec(newVel[1], vy + (10 * dt - vy) * math.min(1, dt * 14), newVel[3])
		end
		if ceilRoom then
			local vmax = ceilRoom > 0 and math.sqrt(2 * 10 * ceilRoom) or 0
			if newVel[2] > vmax then newVel = Vec(newVel[1], vmax, newVel[3]) end
		end
		SetPlayerVelocity(newVel, p)
		flying[#flying + 1] = p
		if S.fuelOn and not free then fuel[p] = math.max(0, fuel[p] - dt / endurance) end
	else
		R.ramp[p] = math.max(0, (R.ramp[p] or 0) - dt * 3)
		if grounded then R.groundedFor[p] = (R.groundedFor[p] or 0) + dt else R.groundedFor[p] = 0 end
		if S.fuelOn and grounded and R.groundedFor[p] >= S.delay then
			fuel[p] = math.min(S.tank, fuel[p] + dt * S.tank / S.refill * refillMul)
		end
	end

	-- Flight stats: peak height above take-off and horizontal distance while airborne.
	if flyingNow then R.airborne[p] = true end
	if grounded or health <= 0 then R.airborne[p] = false end
	local moved = 0
	if R.lastX[p] then moved = math.sqrt((pos[1] - R.lastX[p]) ^ 2 + (pos[3] - R.lastZ[p]) ^ 2) end
	R.lastX[p], R.lastZ[p] = pos[1], pos[3]
	if R.airborne[p] and moved < 20 then
		s.dist = s.dist + moved
		local h = pos[2] - R.baseY[p]
		if h > s.peak then s.peak = h end
		s.dirty = true
	end
end

local function stepPlayers(dt)
	local flying = {}
	for _, p in ipairs(GetAllPlayers()) do
		-- one broken player can never stop the others
		local ok, err = pcall(stepOne, p, dt, flying)
		if not ok and not S.errorShown then
			S.errorShown = true
			DebugPrint("Jetpack (Multiplayer) error: " .. tostring(err))
		end
	end

	if not sameList(flying, S.lastJetting) then
		shared.jetting = flying
		S.lastJetting = flying
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
	if not ok and not S.errorShown then
		S.errorShown = true
		DebugPrint("Jetpack (Multiplayer) server error: " .. tostring(err))
	end
end

end  -- server scope


local function buildClient()  -- client scope

-- text (English only). Keys ending in _sp are used instead in single player.
local STRINGS = {
	title = "Jetpack Settings", host_view = "Host settings", player_view = "Player view",
	host_view_sp = "Single player",
	host_stats = "%d players   -   %d flying", close = "Close", on = "On", off = "Off",
	version_line = "Version %s   -   Revision %d",
	hint_pad = "Confirm: select    Cancel: close    LB / RB: tabs",
	host_only_note = "Only the host can change these settings.",
	not_allowed = "The host has not allowed you to use the jetpack.",

	sec_game = "Game", sec_host = "Host tools", sec_you = "You",
	sec_game_sp = "Jetpack", sec_host_sp = "Tools", sec_you_sp = "Personal",
	tab_flight = "Flight", tab_fuel = "Fuel", tab_players = "Players", tab_admin = "Admin",
	tab_admin_sp = "Tools",
	tab_controls = "Controls", tab_hud = "HUD", tab_stats = "Stats",

	jetpack = "Jetpack", jetpack_sub = "Turn the jetpack on or off for everyone",
	jetpack_sub_sp = "Turn the jetpack on or off",
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
	upgrades = "Upgrades", upgrades_sub = "Fly more to unlock bigger tank, thrust and refill",
	upgrades_sub_sp = "Fly more to unlock a bigger tank, thrust and refill",

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
	host_free_sub_sp = "You never run out of fuel. Resets when you leave.",
	menu_hidden = "Hide settings menu", menu_hidden_sub = "Players no longer see this menu. You always do.",
	announce = "Settings messages", announce_sub = "Tell everyone when you change a setting",
	refill_all = "Refill everyone", refill_all_sp = "Refill tank",
	clear_overrides = "Clear overrides",
	reset_stats = "Reset stats", reset_all = "Reset all", confirm_short = "Confirm?",
	toast_refilled = "Everyone's tank is full", toast_refilled_sp = "Your tank is full",
	toast_cleared = "Player overrides cleared",
	toast_stats_reset = "Flight stats and upgrades reset", toast_all_reset = "All host settings reset",
	toast_all_reset_sp = "All jetpack settings reset",
	reset_all_sp = "Reset all",

	flight_key = "Flight key",
	key_sub_kb = "Click the button, then press a key",
	key_sub_pad = "Pick the action that makes you fly",
	press_key = "Press a key...", clear = "Clear", kb_only = "Keyboard only",
	key_in_use = "That key is already used for flying",
	menu_key = "Menu key", menu_key_sub = "Open and close this menu without pausing", menu_key_none = "Not set",
	effects = "Exhaust effects", effects_sub = "Flames and smoke behind jetpacks",
	fx_off = "Off", fx_light = "Flames", fx_full = "Full",
	accent = "Accent colour", accent_sub = "Buttons and highlights",
	flame = "Flame colour", flame_sub = "Colour of your exhaust flames",
	flame_orange = "Orange", flame_blue = "Blue", flame_green = "Green", flame_purple = "Purple", flame_pink = "Pink",
	last_tab = "Reopen on last tab", last_tab_sub = "Open this menu where you left it",
	reset_personal = "Reset my settings", reset_personal_sub = "Keys, effects, colours and HUD. Host settings stay.",
	reset_personal_sub_sp = "Keys, effects, colours and HUD.",
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
	stat_time = "FLIGHT TIME",
	up_title = "Upgrades", up_off = "Off - turn them on under Fuel",
	up_tier = "Tier %d   +%d%%", up_locked = "Locked", up_max = "MAX",
	pilots = "Pilots", pilots_more = "Pilots (+%d more)",
	col_peak = "PEAK", col_dist = "DISTANCE", col_time = "TIME",

	hud_fuel = "FUEL  %.1fs", hud_empty = "FUEL EMPTY",
	alt_value = "ALT %d m",

	act_jump = "Jump", act_crouch = "Crouch", act_interact = "Interact",
	act_flashlight = "Flashlight", act_grab = "Grab", act_usetool = "Use tool",
	key_space = "Space", key_shift = "Shift", key_ctrl = "Ctrl", key_alt = "Alt",
	key_tab = "Tab", key_rmb = "Right click", key_mmb = "Middle click",
}

-- client state, all in one table
local K = {
	sp = false, open = false, openedAt = 0, tab = "flight", lastTab = "flight", remember = true,
	quickKey = "", kb = "jump", pad = "jump",
	capturing = false, captureTarget = "fly", captureStart = 0, bindTimer = BIND_RESEND, wasPad = false,
	localFuel = nil, lastFuelOn = false,
	autoHide = true, gaugeAlpha = 1, groundTime = 0, gaugeSize = 2, gaugePos = 1, gaugeColor = 1,
	speedHud = false, speedShown = 0, speedUnit = 1, altHud = false, altShown = 0, altGroundY = nil,
	fx = 2, flame = 1, toastText = "", toastUntil = 0, noteText = "", noteUntil = 0, lastNoteSeq = nil,
	page = 1, armedId = nil, armedUntil = 0,
	accent = 1, accentLoaded = false, snd = 0,
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
	local text = (K.sp and STRINGS[key .. "_sp"]) or STRINGS[key] or key
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
	local i = listIndex(list, 4, pid)
	if i then return list[i + 1], list[i + 2], list[i + 3] end
	return 0, 0, 0
end

local function fuelMultipliers(pid)
	local _, ovFuel = getOverrides(pid)
	local _, _, time = getStats(pid)
	local on = shared.upgrades == true
	return ovFuel / 100 * (1 + upBonus(UPGRADES[1], time, on)), 1 + upBonus(UPGRADES[3], time, on)
end

local function listHas(list, pid)
	if type(list) ~= "table" then return false end
	for i = 1, #list do
		if list[i] == pid then return true end
	end
	return false
end

local function setPending(key, value)
	pending[key] = { value = value, expires = GetTime() + 0.6 }
end

local function pendingValue(key, actual)
	local p = pending[key]
	if p and GetTime() < p.expires then return p.value end
	return actual
end

local function usingPad()
	local ok, device = pcall(LastInputDevice)
	return ok and device == 2
end

local function sendBind()
	K.bindTimer = 0
	local pad = usingPad()
	ServerCall("server.setPlayerBind", GetLocalPlayer(), pad and K.pad or K.kb)
end

local function activeBind() return usingPad() and K.pad or K.kb end

local function bindLabel(name)
	if STRINGS["act_" .. name] then return T("act_" .. name) end
	if STRINGS["key_" .. name] then return T("key_" .. name) end
	return string.upper(name)
end

local function cycleList(list, current, step)
	for i = 1, #list do
		if list[i] == current then return list[(i - 1 + step) % #list + 1] end
	end
	return list[1]
end

-- colours -------------------------------------------------------------------

local ACCENT = { 1.0, 0.82, 0.18 }
local ACCENT_PALETTE = {
	{ 1.0, 0.82, 0.18 }, { 0.35, 0.70, 0.95 }, { 0.45, 0.85, 0.55 }, { 0.95, 0.50, 0.75 },
	{ 1.0, 0.55, 0.20 }, { 0.92, 0.32, 0.32 }, { 0.68, 0.50, 0.95 }, { 0.30, 0.82, 0.78 },
	{ 0.72, 0.90, 0.25 }, { 0.92, 0.92, 0.92 },
}
local FLAME_PALETTE = {
	{ 1.0, 0.75, 0.3,  1.0, 0.25, 0.1 },
	{ 0.6, 0.85, 1.0,  0.2, 0.4, 1.0 },
	{ 0.7, 1.0, 0.5,   0.1, 0.8, 0.3 },
	{ 0.85, 0.65, 1.0, 0.5, 0.15, 0.9 },
	{ 1.0, 0.7, 0.85,  0.95, 0.2, 0.5 },
}
local FLAME_KEYS = { "flame_orange", "flame_blue", "flame_green", "flame_purple", "flame_pink" }
local GAUGE_KEYS = { "gc_accent", "gc_cb", "gc_green", "gc_cyan", "gc_white" }
local GAUGE_PALETTE = { false, { 0.34, 0.71, 0.91 }, { 0.45, 0.85, 0.55 }, { 0.30, 0.82, 0.90 }, { 0.95, 0.95, 0.95 } }

local function setAccent(i, save)
	i = ACCENT_PALETTE[i] and i or 1
	K.accent = i
	local c = ACCENT_PALETTE[i]
	ACCENT[1], ACCENT[2], ACCENT[3] = c[1], c[2], c[3]
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

-- personal setters --------------------------------------------------------------

local function setKbBind(v) K.kb = v SetString("savegame.mod.flykey", v) sendBind() end
local function setPadBind(v) K.pad = v SetString("savegame.mod.padkey", v) sendBind() end
local function setGaugeAutoHide(on) K.autoHide = on and true or false SetInt("savegame.mod.hudautohideoff", K.autoHide and 0 or 1) end
local function setSpeedHud(on) K.speedHud = on and true or false SetInt("savegame.mod.speedhud", K.speedHud and 1 or 0) end
local function setSpeedUnit(v) K.speedUnit = SPEED_FACTOR[v] and v or 1 SetInt("savegame.mod.speed_unit", K.speedUnit) end
local function setAltHud(on) K.altHud = on and true or false K.altGroundY = nil SetInt("savegame.mod.alt_hud", K.altHud and 1 or 0) end
local function setFxMode(mode) K.fx = mode % 3 SetInt("savegame.mod.fxmode", K.fx + 1) end
local function setFlame(i) K.flame = FLAME_PALETTE[i] and i or 1 SetInt("savegame.mod.flame", K.flame) end
local function setGaugeSize(v) K.gaugeSize = v SetInt("savegame.mod.gauge_size", v) end
local function setGaugePos(v) K.gaugePos = v SetInt("savegame.mod.gauge_pos", v) end
local function setGaugeColor(i) K.gaugeColor = GAUGE_PALETTE[i] ~= nil and i or 1 SetInt("savegame.mod.gauge_cb", K.gaugeColor - 1) end
local function setQuickKey(key) K.quickKey = key SetString("savegame.mod.menukey", key) end
local function setRememberTab(on) K.remember = on and true or false SetInt("savegame.mod.tab_forget", K.remember and 0 or 1) end

local function startCapture(target)
	K.capturing = true
	K.captureTarget = target or "fly"
	K.captureStart = GetTime()
end

local function pollCapture()
	if not K.capturing or GetTime() - K.captureStart < 0.2 then return end
	local key = InputLastPressedKey()
	if key == "" or key == "lmb" then return end
	K.capturing = false
	if key == "esc" then return end
	if VALID_INPUTS[key] then
		if K.captureTarget == "menu" then
			if key == K.kb then
				K.toastText, K.toastUntil = T("key_in_use"), GetTime() + 3
			else
				setQuickKey(key)
			end
		else
			setKbBind(key)
		end
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

local function spawnExhaust(player, mode)
	local t = GetPlayerTransform(player)
	local origin = TransformToParentPoint(t, Vec(0, 0.85, 0.3))
	local carry = VecScale(GetPlayerVelocity(player), 0.5)
	local f = FLAME_PALETTE[K.flame] or FLAME_PALETTE[1]

	for i = 1, 2 do
		ParticleReset()
		ParticleType("plain")
		ParticleTile(5)
		ParticleColor(f[1], f[2], f[3], f[4], f[5], f[6])
		ParticleRadius(0.07, 0.02, "easeout")
		ParticleAlpha(1.0, 0.0, "easeout", 0, 0.4)
		ParticleEmissive(6, 0, "easeout")
		ParticleGravity(0)
		ParticleDrag(0.2)
		ParticleCollide(0)
		SpawnParticle(origin, VecAdd(carry, Vec(jitter(0.4), -3.5 + jitter(0.5), jitter(0.4))), 0.3)
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

	PointLight(VecAdd(origin, Vec(0, -0.4, 0)), f[4], (f[5] + f[2]) / 2, f[6], 2.5)
end

function client.init()
	K.snd = LoadLoop("jetpack.ogg")

	local v = normalizeBind(GetString("savegame.mod.flykey"))
	if v then K.kb = v end
	local pad = GetString("savegame.mod.padkey")
	if PAD_VALID[pad] then K.pad = pad end
	K.autoHide = GetInt("savegame.mod.hudautohideoff") ~= 1
	K.speedHud = GetInt("savegame.mod.speedhud") == 1
	local unit = GetInt("savegame.mod.speed_unit")
	if SPEED_FACTOR[unit] then K.speedUnit = unit end
	K.altHud = GetInt("savegame.mod.alt_hud") == 1

	v = normalizeBind(GetString("savegame.mod.menukey"))
	if v then K.quickKey = v end
	K.remember = GetInt("savegame.mod.tab_forget") ~= 1
	local savedTab = GetString("savegame.mod.last_tab")
	if savedTab ~= "" then K.lastTab = LEGACY_TABS[savedTab] or savedTab end

	local fx = GetInt("savegame.mod.fxmode")
	if fx >= 1 and fx <= 3 then K.fx = fx - 1 end
	local flame = GetInt("savegame.mod.flame")
	if FLAME_PALETTE[flame] then K.flame = flame end

	local size = GetInt("savegame.mod.gauge_size")
	if size >= 1 and size <= 3 then K.gaugeSize = size end
	local pos = GetInt("savegame.mod.gauge_pos")
	if pos >= 1 and pos <= 4 then K.gaugePos = pos end
	local gc = GetInt("savegame.mod.gauge_cb") + 1
	if GAUGE_PALETTE[gc] ~= nil then K.gaugeColor = gc end
end

function client.tick(dt)
	local me = GetLocalPlayer()
	K.sp = GetPlayerCount() <= 1

	K.bindTimer = K.bindTimer + dt
	local pad = usingPad()
	if K.bindTimer >= BIND_RESEND or pad ~= K.wasPad then
		K.wasPad = pad
		sendBind()
	end

	local menuAllowed = IsPlayerHost(me) or shared.menuHidden ~= true
	if menuAllowed then
		if PauseMenuButton(T("title")) then openSettings() end
		if K.quickKey ~= "" and not K.capturing and InputPressed(K.quickKey) then
			if K.open then K.open = false else openSettings() end
		end
	elseif K.open then
		K.open = false
	end
	pollCapture()

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
		if ok and vel then K.speedShown = K.speedShown + (VecLength(vel) - K.speedShown) * math.min(1, dt * 10) end
	end

	if K.altHud then
		local ok, t = pcall(GetPlayerTransform, me)
		if ok and t then
			local y = t.pos[2]
			if K.altGroundY == nil or health <= 0 or inVehicle or isGrounded(me) then K.altGroundY = y end
			K.altShown = K.altShown + (math.max(0, y - K.altGroundY) - K.altShown) * math.min(1, dt * 10)
		end
	end



	local wantsToFly = localCanFly() and health > 0 and not inVehicle and inputHeld(activeBind())
	local flying = wantsToFly and (not fuelOn or K.localFuel > 0.02)

	if fuelOn then
		local grounded = inVehicle or isGrounded(me)
		local endurance, refillMul = fuelMultipliers(me)

		if flying then
			K.localFuel = math.max(0, K.localFuel - dt / endurance)
		elseif grounded and K.groundTime >= (shared.refillDelay or DELAY_DEFAULT) then
			K.localFuel = math.min(tank, K.localFuel + dt * tank / (shared.refill or REFILL_DEFAULT) * refillMul)
		end

		local serverValue = serverFuelFor(me)
		if serverValue and math.abs(serverValue - K.localFuel) > FUEL_SNAP_DISTANCE then
			K.localFuel = serverValue
		end

		if grounded and not flying then K.groundTime = K.groundTime + dt else K.groundTime = 0 end
		local target = (K.autoHide and K.groundTime > GAUGE_HIDE_DELAY) and 0 or 1
		K.gaugeAlpha = K.gaugeAlpha + (target - K.gaugeAlpha) * math.min(1, dt * GAUGE_FADE_RATE)
	else
		K.groundTime = 0
		K.gaugeAlpha = 1
	end

	if flying then
		PlayLoop(K.snd, GetCameraTransform().pos, SOUND_VOLUME)
		if K.fx > 0 then pcall(spawnExhaust, me, K.fx) end
	end

	local others = shared.jetting
	if type(others) == "table" then
		for i = 1, #others do
			local p = others[i]
			if p ~= me and IsPlayerValid(p) then
				PlayLoop(K.snd, GetPlayerTransform(p).pos, SOUND_VOLUME)
				if K.fx > 0 then pcall(spawnExhaust, p, K.fx) end
			end
		end
	end
end


-- ui toolkit ----------------------------------------------------------------------
-- Every widget is placed by its centre, relative to the current origin.
-- Header y -300..-196, body y -180..204 (sidebar left, tab content right),
-- footer y 216..300. Tab content is laid out from the top of the body down.

local PANEL_W, PANEL_H = 880, 600
local BODY_TOP, BODY_H = -180, 384
local SIDEBAR_X, SIDEBAR_W = -330, 180
local CONTENT_X, CW = 100, 630
local PAD = 20
local LEFT, RIGHT = -CW / 2 + PAD, CW / 2 - PAD
local ROW_H, ROW_STEP = 44, 48

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
				if not bestScore or score < bestScore then best, bestScore = i, score end
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
			if tabs[i].id == K.tab then
				K.tab = tabs[(i - 1 + step) % #tabs + 1].id
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
	if K.gaugePos == 2 then return w / 2, 72, s, true end
	if K.gaugePos == 3 then return 24 + half, h - 72, s, false end
	if K.gaugePos == 4 then return w - 24 - half, h - 72, s, false end
	return w / 2, h - 72, s, false
end

local function gaugeColors()
	if K.gaugeColor == 2 then return GAUGE_PALETTE[2], { 0.84, 0.37, 0.0 } end
	local c = GAUGE_PALETTE[K.gaugeColor]
	return c or ACCENT, { 0.95, 0.28, 0.24 }
end

local function drawGauge()
	local me = GetLocalPlayer()
	if K.gaugeAlpha < 0.02 then return end
	if not localCanFly() or GetPlayerHealth(me) <= 0 or GetPlayerVehicle(me) ~= 0 then return end
	if shared.hostFree == true and IsPlayerHost(me) then return end

	local tank = shared.fuelCap or FUEL_DEFAULT
	local current = K.localFuel or tank
	local fraction = clamp(current / tank, 0, 1)
	local a = K.gaugeAlpha
	local low = fraction > 0.02 and fraction <= 0.22
	local pulse = low and (0.7 + 0.3 * math.sin(GetTime() * 9)) or 1
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
	if K.speedHud then
		lines[#lines + 1] = string.format("%d %s", math.floor(K.speedShown * SPEED_FACTOR[K.speedUnit] + 0.5),
			T(SPEED_UNIT_KEYS[K.speedUnit]))
	end
	if K.altHud then lines[#lines + 1] = T("alt_value", math.floor(K.altShown + 0.5)) end
	for i = 1, #lines do
		label(lines[i], ax, ay + (top and 1 or -1) * (40 + (i - 1) * 24) * s, math.floor(20 * s), WHITE, 0.8)
	end
end

local function drawNote()
	local now = GetTime()
	if now >= K.noteUntil or K.noteText == "" then return end
	local a = math.min(1, (K.noteUntil - now) / 0.6)
	local w = 0
	UiPush()
		UiFont("regular.ttf", 20)
		w = UiGetTextSize(K.noteText)
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

local function onOffText(x, y, on)
	label(on and T("on") or T("off"), x, y, 21, on and GOOD or BAD, 1, "right middle")
end

local function toggleRow(top, title, subtitle, on, canEdit, onToggle, alpha)
	local cy = settingRow(top, title, subtitle, canEdit and 500 or 440, alpha)
	if canEdit then
		if switch(RIGHT - 30, cy, on) then onToggle() end
	else
		onOffText(RIGHT, cy, on)
	end
	return cy
end

local function stepRow(top, title, subtitle, valueText, canEdit, onMinus, onPlus, alpha)
	alpha = alpha or 1
	local cy = settingRow(top, title, subtitle, canEdit and 380 or 400, alpha)
	if canEdit then
		if button("-", RIGHT - 185, cy, 44, 32, BTN, WHITE, 24) then onMinus() end
		label(valueText, RIGHT - 110, cy, 22, ACCENT, alpha, "center middle", 90)
		if button("+", RIGHT - 35, cy, 44, 32, BTN, WHITE, 24) then onPlus() end
	else
		label(valueText, RIGHT, cy, 22, ACCENT, alpha, "right middle", 140)
	end
	return cy
end

local function choiceRow(top, title, subtitle, options, current, canEdit, onPick, alpha)
	local n = #options
	local w = (n == 2) and 120 or ((n == 3) and 104 or ((n == 4) and 80 or 70))
	local cy = settingRow(top, title, subtitle, CW - PAD * 2 - n * (w + 6) - 10, alpha)
	for i = 1, n do
		local x = RIGHT - w / 2 - (n - i) * (w + 6)
		local active = (current == i)
		if button(T(options[i]), x, cy, w, 32, active and ACCENT or BTN, active and DARK or WHITE, 16, not canEdit) then
			onPick(i)
		end
	end
	return cy
end

local function armedButton(id, text, x, y, w, h, onConfirm)
	local armed = (K.armedId == id) and GetTime() < K.armedUntil
	if button(armed and T("confirm_short") or text, x, y, w, h, armed and RED or BTN, WHITE, 16) then
		if armed then
			K.armedId = nil
			onConfirm()
		else
			K.armedId, K.armedUntil = id, GetTime() + 3
		end
	end
end

local function toast(text) K.toastText, K.toastUntil = text, GetTime() + 3 end



-- tabs ---------------------------------------------------------------------------------------

function TABS.flight(c)
	local h = c.isHost
	local a = c.enabled and 1 or 0.5

	toggleRow(rowTop(1), T("jetpack"), T("jetpack_sub"), c.enabled, h, function()
		do local nv = not (c.enabled) setPending("enabled", nv) ServerCall("server.setEnabled", nv) end
	end)

	local function setThrust(v) local nv = clampThrust(v) setPending("thrust", nv) ServerCall("server.setThrustPct", nv) end
	stepRow(rowTop(2), T("thrust"), T("thrust_sub", 50, 150), c.thrust .. "%", h,
		function() setThrust(c.thrust - 10) end,
		function() setThrust(c.thrust + 10) end, a)

	local function setCap(v) local nv = clampCap(v) setPending("cap", nv) ServerCall("server.setSpeedCap", nv) end
	stepRow(rowTop(3), T("speed_cap"), T("speed_cap_sub"),
		c.cap == 0 and T("speed_off") or T("speed_value", c.cap), h,
		function()
			if c.cap == 0 then setCap(CAP_MAX) else setCap(math.max(CAP_MIN, c.cap - CAP_STEP)) end
		end,
		function()
			if c.cap == 0 then return end
			if c.cap + CAP_STEP > CAP_MAX then setCap(0) else setCap(c.cap + CAP_STEP) end
		end, a)

	local function setCeiling(v) local nv = clampCeiling(v) setPending("ceiling", nv) ServerCall("server.setCeiling", nv) end
	stepRow(rowTop(4), T("ceiling"), T("ceiling_sub"),
		c.ceiling == 0 and T("speed_off") or string.format("%d m", c.ceiling), h,
		function()
			if c.ceiling == 0 then setCeiling(CEIL_MAX) else setCeiling(math.max(CEIL_MIN, c.ceiling - CEIL_STEP)) end
		end,
		function()
			if c.ceiling == 0 then return end
			if c.ceiling + CEIL_STEP > CEIL_MAX then setCeiling(0) else setCeiling(c.ceiling + CEIL_STEP) end
		end, a)

	toggleRow(rowTop(5), T("smooth"), T("smooth_sub"), c.smooth, h, function()
		do local nv = not (c.smooth) setPending("smooth", nv) ServerCall("server.setSmooth", nv) end
	end, a)

	toggleRow(rowTop(6), T("hover_assist"), T("hover_assist_sub"), c.hover, h, function()
		do local nv = not (c.hover) setPending("hover", nv) ServerCall("server.setHover", nv) end
	end, a)
end

-- Fuel: four fuel rows, then upgrades. Dimmed rows still work.
function TABS.fuel(c)
	local h = c.isHost
	local fa = c.fuelOn and 1 or 0.5

	toggleRow(rowTop(1), T("fuel_system"), T("fuel_sub"), c.fuelOn, h, function()
		do local nv = not (c.fuelOn) setPending("fuelOn", nv) ServerCall("server.setFuelEnabled", nv) end
	end)

	local function setTank(v) local nv = clampFuel(v) setPending("tank", nv) ServerCall("server.setFuelCap", nv) end
	stepRow(rowTop(2), T("tank"), T("tank_sub"), c.tank .. " s", h,
		function() setTank(c.tank - 1) end, function() setTank(c.tank + 1) end, fa)

	local function setRefill(v) local nv = clampRefill(v) setPending("refill", nv) ServerCall("server.setRefill", nv) end
	stepRow(rowTop(3), T("refill_time"), T("refill_time_sub"), string.format("%.1f s", c.refill), h,
		function() setRefill(c.refill - REFILL_STEP) end,
		function() setRefill(c.refill + REFILL_STEP) end, fa)

	local function setDelay(v) local nv = clampDelay(v) setPending("delay", nv) ServerCall("server.setRefillDelay", nv) end
	stepRow(rowTop(4), T("refill_delay"), T("refill_delay_sub"), string.format("%.1f s", c.refillDelay), h,
		function() setDelay(c.refillDelay - DELAY_STEP) end,
		function() setDelay(c.refillDelay + DELAY_STEP) end, fa)

	toggleRow(rowTop(5), T("upgrades"), T("upgrades_sub"), c.upgrades, h, function()
		do local nv = not (c.upgrades) setPending("upgrades", nv) ServerCall("server.setUpgrades", nv) end
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

function TABS.stats(c)
	local me = GetLocalPlayer()
	local peak, dist, time = getStats(me)

	statCard(-215, 48, 200, 96, STAT_COLORS[1], T("stat_peak"), fmtDist(peak), T("stat_peak_sub"))
	statCard(0, 48, 200, 96, STAT_COLORS[2], T("stat_dist"), fmtDist(dist), T("stat_dist_sub"))
	statCard(215, 48, 200, 96, STAT_COLORS[3], T("stat_time"), fmtTime(time), "")

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
			UiRoundedRect(math.max(6, 250 * clamp(frac, 0, 1)), 6, 3)
		UiPop()
		local text = tier > 0 and T("up_tier", tier, math.floor(up.bonus[tier] * 100 + 0.5)) or T("up_locked")
		if tier >= #up.at then text = text .. "   " .. T("up_max") end
		label(text, RIGHT, y, 15, tier > 0 and ACCENT or WHITE, tier > 0 and a or 0.5 * a, "right middle", 190)
	end

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

local function mulColor(v) if v ~= 100 then return ACCENT end return WHITE end

function TABS.players(c)
	toggleRow(rowTop(1), T("approval"), c.restrict and T("approval_on_sub") or T("approval_off_sub"),
		c.restrict, true, function() do local nv = not (c.restrict) setPending("restrict", nv) ServerCall("server.setRestrict", nv) end end)

	if button(T("allow_all"), -155, 72, 300, 26, GREEN, WHITE, 16, not c.restrict) then
		ServerCall("server.setAllowedAll", true)
	end
	if button(T("block_all"), 155, 72, 300, 26, RED, WHITE, 16, not c.restrict) then
		ServerCall("server.setAllowedAll", false)
	end

	local players = GetAllPlayers()
	local perPage = 3
	local pages = math.max(1, math.ceil(#players / perPage))
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

local function resetHostSettings()
	for _, key in ipairs({ "enabled", "announce", "hover", "smooth" }) do setPending(key, true) end
	for _, key in ipairs({ "menuHidden", "hostFree", "restrict", "upgrades" }) do setPending(key, false) end
	applyProfileHere("original")
	setPending("refill", REFILL_DEFAULT)
	setPending("delay", DELAY_DEFAULT)
	setPending("ceiling", 0)
	ServerCall("server.resetAll")
end

function TABS.admin(c)
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
		do local nv = not (c.hostFree) setPending("hostFree", nv) ServerCall("server.setHostFree", nv) end
	end, c.fuelOn and 1 or 0.55)

	local y = 192
	if c.multiplayer then
		local hidden = pendingValue("menuHidden", shared.menuHidden == true)
		toggleRow(192, T("menu_hidden"), T("menu_hidden_sub"), hidden, true, function()
			do local nv = not (hidden) setPending("menuHidden", nv) ServerCall("server.setMenuHidden", nv) end
		end)

		local announce = pendingValue("announce", shared.announce ~= false)
		toggleRow(246, T("announce"), T("announce_sub"), announce, true, function()
			do local nv = not (announce) setPending("announce", nv) ServerCall("server.setAnnounce", nv) end
		end)
		y = 300
	end

	-- actions, spread evenly
	local actions = {}
	actions[#actions + 1] = { text = T("refill_all"), off = not c.fuelOn, run = function()
		ServerCall("server.refillAll")
		toast(T("toast_refilled"))
	end }
	if c.multiplayer then
		actions[#actions + 1] = { text = T("clear_overrides"), run = function()
			ServerCall("server.resetOverrides")
			toast(T("toast_cleared"))
		end }
	end
	actions[#actions + 1] = { text = T("reset_stats"), armed = "stats", run = function()
		ServerCall("server.resetStats")
		toast(T("toast_stats_reset"))
	end }
	actions[#actions + 1] = { text = T("reset_all"), armed = "all", run = function()
		resetHostSettings()
		toast(T("toast_all_reset"))
	end }

	local cy = y + 24
	card(0, cy, CW, 48)
	local n = #actions
	local w = (CW - 24) / n - 8
	for i, a in ipairs(actions) do
		local x = -CW / 2 + 12 + (i - 0.5) * (CW - 24) / n
		if a.armed then
			armedButton(a.armed, a.text, x, cy, w, 36, a.run)
		elseif button(a.text, x, cy, w, 36, BTN, WHITE, 16, a.off) then
			a.run()
		end
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
	setKbBind("jump")
	setPadBind("jump")
	setFxMode(2)
	setFlame(1)
	setAccent(1, true)
	setQuickKey("")
	setRememberTab(true)
end

local function keyPicker(cy, target, current, resetKey, resetText, onReset)
	local waiting = K.capturing and K.captureTarget == target
	local text = waiting and T("press_key") or (current == "" and T("menu_key_none") or bindLabel(current))
	if button(text, 134, cy, 170, 32, waiting and ACCENT or BTN, waiting and DARK or WHITE, 18) then
		if waiting then K.capturing = false else startCapture(target) end
	end
	if button(resetText, 260, cy, 70, 32, BTN, WHITE, 15, current == resetKey) then
		K.capturing = false
		onReset()
	end
end

local function padPicker(cy, current, onSet)
	if button("<", 77, cy, 40, 32, BTN, WHITE, 22) then onSet(cycleList(PAD_ACTIONS, current, -1)) end
	if button(bindLabel(current), 176, cy, 150, 32, ACCENT, DARK, 18) then onSet(cycleList(PAD_ACTIONS, current, 1)) end
	if button(">", 275, cy, 40, 32, BTN, WHITE, 22) then onSet(cycleList(PAD_ACTIONS, current, 1)) end
end

local function swatchRow(top, title, subtitle, palette, current, onPick, colorOf)
	local cy = settingRow(top, title, subtitle, 200)
	local n = #palette
	for i = 1, n do
		local x = RIGHT - 15 - (n - i) * 31
		local c = colorOf(palette[i])
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
		if hit(x, cy, 28, 28) then onPick(i) end
	end
end

-- Everything here only affects this player and is saved on this PC.
function TABS.controls(c)
	local pad = nav.active

	local cy = settingRow(rowTop(1), T("flight_key"), pad and T("key_sub_pad") or T("key_sub_kb"), 300)
	if pad then padPicker(cy, K.pad, setPadBind)
	else keyPicker(cy, "fly", K.kb, "jump", T("reset"), function() setKbBind("jump") end) end

	cy = settingRow(rowTop(2), T("menu_key"), T("menu_key_sub"), 300)
	if pad then
		label(T("kb_only"), RIGHT, cy, 18, WHITE, 0.5, "right middle", 200)
	else
		keyPicker(cy, "menu", K.quickKey, "", T("clear"), function() setQuickKey("") end)
	end

	choiceRow(rowTop(3), T("effects"), T("effects_sub"), { "fx_off", "fx_light", "fx_full" },
		pendingValue("fx", K.fx + 1), true, function(i)
			setPending("fx", i)
			setFxMode(i - 1)
		end)

	choiceRow(rowTop(4), T("flame"), T("flame_sub"), FLAME_KEYS, pendingValue("flame", K.flame), true, function(i)
		setPending("flame", i)
		setFlame(i)
	end)

	swatchRow(rowTop(5), T("accent"), T("accent_sub"), ACCENT_PALETTE, K.accent,
		function(i) setAccent(i, true) end, function(col) return col end)

	toggleRow(rowTop(6), T("last_tab"), T("last_tab_sub"), K.remember, true, function()
		setRememberTab(not K.remember)
	end)

	cy = settingRow(rowTop(7), T("reset_personal"), T("reset_personal_sub"), 330)
	armedButton("personal", T("reset"), RIGHT - 90, cy, 180, 32, function()
		resetPersonal()
		toast(T("toast_personal_reset"))
	end)
end

function TABS.hud(c)
	local autoHide = pendingValue("gauge", K.autoHide)
	toggleRow(rowTop(1), T("gauge"), T("gauge_sub"), autoHide, true, function()
		setPending("gauge", not autoHide)
		setGaugeAutoHide(not autoHide)
	end)

	local showSpeed = pendingValue("speedhud", K.speedHud)
	toggleRow(rowTop(2), T("speed_hud"), T("speed_hud_sub"), showSpeed, true, function()
		setPending("speedhud", not showSpeed)
		setSpeedHud(not showSpeed)
	end)

	local showAlt = pendingValue("althud", K.altHud)
	toggleRow(rowTop(3), T("alt_hud"), T("alt_hud_sub"), showAlt, true, function()
		setPending("althud", not showAlt)
		setAltHud(not showAlt)
	end)

	choiceRow(rowTop(4), T("speed_unit"), nil, SPEED_UNIT_KEYS, pendingValue("sunit", K.speedUnit), true, function(i)
		setPending("sunit", i)
		setSpeedUnit(i)
	end, showSpeed and 1 or 0.5)

	choiceRow(rowTop(5), T("gauge_size"), nil, { "size_s", "size_m", "size_l" },
		pendingValue("gsize", K.gaugeSize), true, function(i)
			setPending("gsize", i)
			setGaugeSize(i)
		end)

	choiceRow(rowTop(6), T("gauge_pos"), nil, { "pos_bottom", "pos_top", "pos_left", "pos_right" },
		pendingValue("gpos", K.gaugePos), true, function(i)
			setPending("gpos", i)
			setGaugePos(i)
		end)

	choiceRow(rowTop(7), T("gauge_color"), nil, GAUGE_KEYS, pendingValue("gcol", K.gaugeColor), true, function(i)
		setPending("gcol", i)
		setGaugeColor(i)
	end)
end


-- settings window ---------------------------------------------------------------------------

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
		if entry.section ~= section then
			section = entry.section
			label(string.upper(T(section)), SIDEBAR_X - (SIDEBAR_W - 24) / 2 + 4, y + 13, 13, WHITE, 0.4, "left middle")
			y = y + 24
		end
		local active = (K.tab == entry.id)
		if button(entry.name, SIDEBAR_X, y + 19, SIDEBAR_W - 24, 36,
			active and ACCENT or BTN, active and DARK or WHITE, 19) then
			K.tab = entry.id
			K.capturing = false
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
	nav.items = {}
	nav.offset = 0
	nav.offsetY = 0

	local c = {
		isHost = isHost,
		multiplayer = multiplayer,
		playerCount = playerCount,
		flyingCount = type(shared.jetting) == "table" and #shared.jetting or 0,
		enabled = pendingValue("enabled", shared.enabled ~= false),
		thrust = pendingValue("thrust", shared.thrustPct or THRUST_DEFAULT),
		smooth = pendingValue("smooth", shared.smooth ~= false),
		cap = pendingValue("cap", shared.speedCap or 0),
		fuelOn = pendingValue("fuelOn", shared.fuelEnabled == true),
		tank = pendingValue("tank", shared.fuelCap or FUEL_DEFAULT),
		refill = pendingValue("refill", shared.refill or REFILL_DEFAULT),
		refillDelay = pendingValue("delay", shared.refillDelay or DELAY_DEFAULT),
		hover = pendingValue("hover", shared.hover ~= false),
		upgrades = pendingValue("upgrades", shared.upgrades == true),
		ceiling = pendingValue("ceiling", shared.ceiling or 0),
		hostFree = pendingValue("hostFree", shared.hostFree == true),
		restrict = pendingValue("restrict", shared.restrict == true),
		blocked = (shared.restrict == true) and not isHost and not inAllowedList(me),
	}

	local tabs = buildTabs(isHost, multiplayer)
	local known = false
	for i = 1, #tabs do
		if tabs[i].id == K.tab then known = true end
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
		local fit = math.min(1, (UiHeight() - 24) / PANEL_H, (UiWidth() - 24) / PANEL_W)
		if fit < 1 then UiScale(fit) end
		UiAlign("center middle")

		UiColor(0, 0, 0, 0.35)
		UiRoundedRect(PANEL_W + 28, PANEL_H + 28, 32)
		UiColor(1, 1, 1, 0.10)
		UiRoundedRect(PANEL_W + 4, PANEL_H + 4, 22)
		UiColor(PANEL[1], PANEL[2], PANEL[3], 0.98)
		UiRoundedRect(PANEL_W, PANEL_H, 20)

		drawHeader(c)
		drawSidebar(tabs)

		UiPush()
			UiTranslate(CONTENT_X, BODY_TOP)
			nav.offset = CONTENT_X
			nav.offsetY = BODY_TOP
			local drawTab = TABS[K.tab] or TABS.flight
			local ok, err = pcall(drawTab, c)      -- a broken tab never takes the whole menu down
			if not ok then label("Tab error: " .. tostring(err), 0, 40, 16, BAD, 1, "center middle", CW - 20) end
		UiPop()
		nav.offset = 0
		nav.offsetY = 0

		drawFooter(isHost)
	UiPop()

	drawNote()
	handleControllerInput(tabs)
end

function client.draw()
	if not K.accentLoaded then
		K.accentLoaded = true
		setAccent(GetInt("savegame.mod.accent"), false)
	end

	if not K.open then
		if shared.fuelEnabled then drawGauge() end
		if K.speedHud or K.altHud then drawSpeed() end
		drawNote()
		return
	end

	drawWindow()
end

end

buildClient()
