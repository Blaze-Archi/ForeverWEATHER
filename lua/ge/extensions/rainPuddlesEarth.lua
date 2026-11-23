-- ForeverWEATHER x BeamNG.Earth bridge (GE extension 'rainPuddlesEarth') 2.0.0
--
-- Ships with ForeverWEATHER (Rain Puddles, extension 'rainPuddles') 1.0.2 and works with BeamNG.Earth (extension
-- 'beamngEarth_weather') on BeamNG.drive 0.40. On the BeamNG.Earth map, in BeamNG.Earth's Real weather mode, the real
-- weather (Open-Meteo, through BeamNG.Earth's server) drives the whole wet look:
--   rain amount      BeamNG.Earth's own rain share (rainNow: smoothed, 0 above the cloud base, in step with its rain sound)
--   drop size        rain rate and weather code (Marshall-Palmer drop sizes; drizzle fine, showers and storms coarse)
--   wetting, drying  the rain rate wets the road faster; temperature, wind and sun set how long it takes to dry
--   puddles          how much water fell over the last minutes: coverage, and rain ripples (rate + wind)
--   road film        heavy rain makes the film smoother, more reflective and floods the road; drizzle stays damp
--   tyre spray       more water on the road throws more spray
--   snow             no rain from Rain Puddles (BeamNG.Earth draws its snow); wet slush above freezing
--   wind, clock      BeamNG.Earth sets them in the game, and ForeverWEATHER already follows the game's wind and clock
-- The look values (road film, puddles, spray) are the player's own values scaled by the weather, so the player's taste
-- stays. Everything goes through Rain Puddles' external weather API (setExternalWeather): nothing of it is saved, the
-- player's values come back when BeamNG.Earth goes to Manual, the map is left, or either mod is switched off/unloaded.
-- BeamNG.Earth's own rain particles (the level's Precipitation 'bngEarthRain') are hidden while Rain Puddles draws the
-- rain; its snow, clouds, fog, wind, clock and sounds stay BeamNG.Earth's. Only public Lua of both mods is used.
--
-- Console (GE Lua):
--   rainPuddlesEarth.status()               what it does now (also written to the log)
--   rainPuddlesEarth.setEnabled(false)      hand everything back (saved)
--   rainPuddlesEarth.set('rainGain', 1.2)   settings: enabled, rainGain (0-3), weatherLook, preWet, particles (saved)

local M = {}

local TAG = 'rainPuddlesEarth'
local VERSION = '2.0.0'
local SRC = 'beamngEarth'
local LABEL = 'BeamNG.Earth (real weather)'
local SETTINGS_FILE = '/settings/rainPuddles_earth.json'
local OLD_RESTORE_FILE = '/settings/rainPuddles_earth_restore.json'   -- 1.0 journal, given back once
local RP_SETTINGS_FILE = '/settings/rainPuddles.json'

local RP_EXT = 'rainPuddles'
local EARTH_EXT = 'beamngEarth_weather'
local EARTH_LEVEL_DEFAULT = 'beamng_earth'
local EARTH_RAIN_DEFAULT = 'bngEarthRain'

local TICK_S = 0.25
local SEND_MIN_S = 1.0          -- the weather values go to Rain Puddles at most once a second unless something jumps
local PREWET_WINDOW_S = 90      -- the first weather message this soon after arriving wets the ground at once
local PREWET_MIN_MMH = 0.05     -- BeamNG.Earth's own "it rains" threshold (weather.lua precipPct)

local defaults = {
  enabled = true,
  rainGain = 1.0,      -- Rain Puddles' rain = BeamNG.Earth's rain share x this
  weatherLook = true,  -- the weather also drives drop size, drying, puddles, road film and spray (false: rain amount only)
  preWet = true,       -- arriving where it really rains, the ground is wet at once
  particles = true,    -- draw particle rain (Rain Puddles' native-rain recipe) when the player's 'Native rain' is on
}
local ranges = { rainGain = { 0, 3 } }

local cfg = {}
local clock, tickTimer = 0, 0
local warned, errors = {}, 0
local sessionNoted = false

local function newState()
  return { engaged = false, levelAt = 0, rainObjId = nil, earthRainHidden = false, preWetDone = false,
           handNoted = false, rainNowAtStart = nil, rainNowLive = true, lastSentAt = -1e9, sent = nil,
           wx = nil, why = 'idle' }
end
local st = newState()

------------------------------------------------------------------------------------------------------------------------
-- small helpers

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end
local function round(v) return math.floor(v + 0.5) end

local function warnOnce(key, msg)
  if warned[key] then return end
  warned[key] = true
  log('W', TAG, msg)
end

local function toast(msg, kind)
  local gh = rawget(_G, 'guihooks')
  if gh and gh.trigger then
    pcall(gh.trigger, 'toastrMsg', { type = kind or 'info', title = 'ForeverWEATHER x BeamNG.Earth', msg = msg })
  end
end

local function fileExists(path)
  local ok, yes = pcall(function() return FS:fileExists(path) end)
  return ok and yes and true or false
end
local function readJson(path)
  if not fileExists(path) then return nil end
  local ok, data = pcall(jsonReadFile, path)
  if ok and type(data) == 'table' then return data end
  return nil
end
local function writeJson(path, data)
  local ok, err = pcall(jsonWriteFile, path, data, true)
  if not ok then warnOnce('write' .. path, 'could not write ' .. path .. ': ' .. tostring(err)) end
  return ok
end

local function levelId()
  if type(getCurrentLevelIdentifier) ~= 'function' then return nil end
  local ok, id = pcall(getCurrentLevelIdentifier)
  if ok and type(id) == 'string' and id ~= '' then return id end
  return nil
end

local function camPos()
  local cam = rawget(_G, 'core_camera')
  if not cam or type(cam.getPositionXYZ) ~= 'function' then return nil end
  local ok, x, y, z = pcall(cam.getPositionXYZ)
  if ok and tonumber(x) and tonumber(y) and tonumber(z) then return x, y, z end
  return nil
end

local function className(o)
  local ok, c = pcall(function() return o:getClassName() end)
  return ok and c or nil
end
local function objName(o)
  local ok, n = pcall(function() return o:getName() end)
  return ok and n or nil
end
local function objId(o)
  local ok, id = pcall(function() return o:getID() end)
  return ok and tonumber(id) or nil
end
local function isHiddenObj(o)
  local ok, h = pcall(function() return o:isHidden() end)
  if ok and type(h) == 'boolean' then return h end
  ok, h = pcall(function() return o.hidden end)
  if ok and h ~= nil then return h == true or h == 1 or h == '1' end
  return nil
end
local function setHiddenObj(o, hidden)
  if pcall(function() o:setHidden(hidden) end) then return true end
  return pcall(function() o.hidden = hidden end)
end
local function setField(o, field, value)
  pcall(function() o:setField(field, 0, tostring(value)) end)
end

------------------------------------------------------------------------------------------------------------------------
-- the two mods (rawget: reading extensions.<name> would load an extension that is not loaded)

local function rpExt()
  local m = rawget(_G, RP_EXT)
  if type(m) == 'table' and type(m.getSettings) == 'function' then return m end
  return nil
end
local function rpHasApi(m)
  return m and type(m.setExternalWeather) == 'function' and type(m.clearExternalWeather) == 'function'
end
local function earthExt()
  local w = rawget(_G, EARTH_EXT)
  if type(w) == 'table' then return w end
  return nil
end

local function isEarthLevel(w)
  local id = levelId()
  if not id then return false end
  local want = (type(w.LEVEL_ID) == 'string' and w.LEVEL_ID ~= '') and w.LEVEL_ID or EARTH_LEVEL_DEFAULT
  return id == want
end

local function earthMode(w)
  if type(w.getMode) ~= 'function' then return 'real' end
  local ok, mode = pcall(w.getMode)
  return ok and mode or nil
end

-- The rain BeamNG.Earth shows now, 0..1 (its share of the drop pool, sqrt(mm/h / 8), smoothed over a minute). rainNow
-- survives a level load: until BeamNG.Earth's first update on the new map it is the last map's value.
local function earthRainShare(w)
  local now = tonumber(w.rainNow)
  if not st.rainNowLive then
    if now ~= st.rainNowAtStart or clock - st.levelAt > (tonumber(w.GRACE_S) or 20) + 2 then
      st.rainNowLive = true
    else
      return 0
    end
  end
  return clamp(now or 0, 0, 1)
end

-- the latest weather message (code, cover, wind, visM, rainMmH, snowCmH, slTempC, ...)
local function earthMsg(w)
  if type(w.current) ~= 'function' then return nil end
  local ok, msg = pcall(w.current)
  if ok and type(msg) == 'table' then return msg end
  return nil
end

local function targetShare(w, msg)
  local rate = msg and tonumber(msg.rainMmH) or 0
  if rate <= PREWET_MIN_MMH then return 0 end
  local full = tonumber(w.RAIN_FULL_MMH) or 8
  local pct = nil
  if type(w.precipPct) == 'function' then
    local okP, p = pcall(w.precipPct, rate, full)
    pct = okP and tonumber(p) or nil
  end
  return clamp(pct or clamp(math.sqrt(rate / full), 0.08, 1), 0, 1)
end

------------------------------------------------------------------------------------------------------------------------
-- settings

local function loadCfg()
  cfg = {}
  for k, v in pairs(defaults) do cfg[k] = v end
  local data = readJson(SETTINGS_FILE)
  if data then
    for k, v in pairs(data) do
      if defaults[k] ~= nil and type(v) == type(defaults[k]) then cfg[k] = v end
    end
  end
  for k, r in pairs(ranges) do cfg[k] = clamp(cfg[k], r[1], r[2]) end
end

local function saveCfg()
  local out = { version = VERSION }
  for k, v in pairs(cfg) do out[k] = v end
  writeJson(SETTINGS_FILE, out)
end

-- The 1.0 companion kept the player's values in a journal and wrote them into Rain Puddles while it ran. Give anything
-- it still holds back once (into Rain Puddles, or its settings file while it is not loaded), then the journal is gone.
local function oldJournalGiveBack(m)
  local data = readJson(OLD_RESTORE_FILE)
  if not (data and data.active == true) then return end
  local vals = {}
  if type(data.guards) == 'table' then
    for _, k in ipairs({ 'followWeather', 'autoClouds', 'precipitation' }) do
      if type(data.guards[k]) == 'boolean' then vals[k] = data.guards[k] end
    end
  end
  if tonumber(data.rain) then vals.rain = tonumber(data.rain) end
  if m and type(m.setSetting) == 'function' then
    for k, v in pairs(vals) do pcall(m.setSetting, k, v) end
  else
    local rp = readJson(RP_SETTINGS_FILE)
    if not rp then return end
    for k, v in pairs(vals) do rp[k] = v end
    if not writeJson(RP_SETTINGS_FILE, rp) then return end
  end
  writeJson(OLD_RESTORE_FILE, { active = false, version = VERSION, note = 'given back by the 2.0 bridge' })
  log('I', TAG, 'values held by the 1.0 companion are back in Rain Puddles')
end

------------------------------------------------------------------------------------------------------------------------
-- BeamNG.Earth's own rain particles

-- The level's Precipitation named RAIN_NAME, looked up by class too: BeamNG.Earth 1.8 also registers its rain SOUND
-- emitter as 'bngEarthRain', and the name then finds whichever object came last.
local function earthRainObject(w)
  if st.rainObjId then
    local o = scenetree.findObjectById(st.rainObjId)
    if o and className(o) == 'Precipitation' then return o end
    st.rainObjId = nil
  end
  local name = (type(w.RAIN_NAME) == 'string' and w.RAIN_NAME ~= '') and w.RAIN_NAME or EARTH_RAIN_DEFAULT
  local o = scenetree.findObject(name)
  if o and className(o) == 'Precipitation' then
    st.rainObjId = objId(o)
    return o
  end
  local okL, list = pcall(scenetree.findClassObjects, 'Precipitation')
  if okL and type(list) == 'table' then
    for _, nm in ipairs(list) do
      local c = scenetree.findObject(nm)
      if c and className(c) == 'Precipitation' and objName(c) == name then
        st.rainObjId = objId(c)
        return c
      end
    end
  end
  return nil
end

local function earthWantsRainVisible(w)
  return earthMode(w) == 'real' and (tonumber(w.rainNow) or 0) > 0.001
end

local function hideEarthRain(w)
  st.earthRainHidden = true
  local o = earthRainObject(w)
  if o and isHiddenObj(o) == false then setHiddenObj(o, true) end
end

local function restoreEarthRain(w)
  if not st.earthRainHidden then return end
  st.earthRainHidden = false
  if not w then return end
  local o = earthRainObject(w)
  if o then setHiddenObj(o, not earthWantsRainVisible(w)) end
end

------------------------------------------------------------------------------------------------------------------------
-- particle rain (only when the player's own 'Native rain' is on; ForeverWEATHER's GPU rain needs none)
-- Rain Puddles would take over the nearest Precipitation object of the level (BeamNG.Earth's rain or snow), so its
-- 'precipitation' is held off here and the same rain is drawn with its 1.0 recipe on objects of our own.

local P_HEAVY, P_FINE = 'RainPuddlesEarth_Rain', 'RainPuddlesEarth_Spray'
local pcache = {}

local function deleteNamed(name)
  pcache[name] = nil
  local o = scenetree.findObject(name)
  if o then pcall(function() o:delete() end) end
end
local function clearParticles()
  deleteNamed(P_HEAVY)
  deleteNamed(P_FINE)
end

local function createPrecip(name, dataBlock)
  local root = scenetree.findObject('MissionGroup')
  if not root then return nil end
  if not scenetree.findObject(dataBlock) then
    warnOnce('db_' .. dataBlock, 'particle rain skipped: datablock "' .. dataBlock .. '" not available')
    return nil
  end
  local okC, obj = pcall(createObject, 'Precipitation')
  if not okC or not obj then
    warnOnce('precip_class', 'particle rain skipped: could not create a Precipitation object')
    return nil
  end
  if not pcall(function() obj.dataBlock = dataBlock end) then setField(obj, 'dataBlock', dataBlock) end
  setField(obj, 'numDrops', 0)
  setField(obj, 'boxWidth', 120)
  setField(obj, 'boxHeight', 80)
  setField(obj, 'dropSize', 0.07)
  setField(obj, 'splashSize', 0.16)
  setField(obj, 'splashMS', 80)
  setField(obj, 'fadeDist', 40)
  setField(obj, 'fadeDistEnd', 75)
  setField(obj, 'useTurbulence', 1)
  setField(obj, 'useWind', 1)
  pcall(function() obj.canSave = false end)
  if not pcall(function() obj:registerObject(name) end) then
    pcall(function() obj:delete() end)
    warnOnce('precip_reg', 'particle rain skipped: could not register ' .. name)
    return nil
  end
  pcall(function() root:addObject(obj) end)
  pcache[name] = {}
  return obj
end

local function setNumDrops(o, n)
  pcall(function() o.numDrops = n end)
  setField(o, 'numDrops', n)
end

local function shapePrecip(name, o, n, rain, box, size, follow, cx, cy, cz, above)
  local c = pcache[name] or {}
  pcache[name] = c
  if c.n ~= n then
    setNumDrops(o, n)
    c.n = n
  end
  if not c.rain or math.abs(c.rain - rain) > 0.01 then
    setField(o, 'boxWidth', string.format('%.2f', box[1]))
    setField(o, 'boxHeight', string.format('%.2f', box[2]))
    setField(o, 'dropSize', string.format('%.4f', size[1]))
    if size[2] then setField(o, 'splashSize', string.format('%.4f', size[2])) end
    c.rain = rain
  end
  if follow and cx then
    local z = cz + above
    if not c.x or math.abs(c.x - cx) + math.abs(c.y - cy) + math.abs(c.z - z) > 2 then
      setField(o, 'position', string.format('%.3f %.3f %.3f', cx, cy, z))
      c.x, c.y, c.z = cx, cy, z
    end
  end
end

local function updateParticles(want, s, rain)
  rain = clamp(tonumber(rain) or 0, 0, 1)
  if not want or rain <= 0.02 or not levelId() then
    if scenetree.findObject(P_HEAVY) or scenetree.findObject(P_FINE) then clearParticles() end
    return
  end
  local maxDrops = clamp(tonumber(s.precipMaxDrops) or 12000, 0, 24000)
  local follow = s.precipFollow ~= false
  local cx, cy, cz = camPos()
  local heavy = scenetree.findObject(P_HEAVY) or createPrecip(P_HEAVY, 'rain_medium')
  if heavy then
    shapePrecip(P_HEAVY, heavy, round(maxDrops * 0.68 * (rain ^ 1.15)), rain,
      { 100 + 80 * rain, 60 + 55 * rain }, { 0.05 + 0.07 * rain, 0.12 + 0.16 * rain }, follow, cx, cy, cz, 24.0)
  end
  if rain >= 0.52 then
    local fine = scenetree.findObject(P_FINE) or createPrecip(P_FINE, 'rain_drop')
    if fine then
      shapePrecip(P_FINE, fine, round(maxDrops * 0.32 * math.max(0, (rain - 0.40) / 0.60)), rain,
        { 90 + 70 * rain, 55 + 45 * rain }, { 0.04 + 0.04 * rain }, follow, cx, cy, cz, 22.0)
    end
  elseif scenetree.findObject(P_FINE) then
    deleteNamed(P_FINE)
  end
end

------------------------------------------------------------------------------------------------------------------------
-- the weather -> ForeverWEATHER

-- Smoothed weather state. Message values follow BeamNG.Earth's own fade (95 % in LERP_S); 'water' is a slow memory of the
-- rain rate (mm/h) for the puddles: they fill over minutes of rain and drain slower than they fill.
local function newWx()
  return { rate = 0, snow = 0, temp = 12, wind = 0, gust = 0, cover = 0.5, vis = 20000, code = 0, water = 0,
           fog = 0, init = false }
end

local function wxStep(w, msg, dt, rateNow)
  local x = st.wx or newWx()
  st.wx = x
  local T = math.max(tonumber(w.LERP_S) or 60, 1)
  local a = 1 - math.exp(-3 * dt / T)
  local cover = msg and msg.cover or {}
  local wind = msg and msg.wind or {}
  local tgt = {
    snow = tonumber(msg and msg.snowCmH) or 0,
    temp = tonumber(msg and (msg.tempC or msg.slTempC)) or x.temp,
    wind = tonumber(wind.ms) or 0,
    gust = math.max(tonumber(wind.gustMs) or 0, tonumber(wind.ms) or 0),
    cover = math.max(tonumber(cover.low) or 0, tonumber(cover.mid) or 0) / 100,
    vis = tonumber(msg and msg.visM) or 20000,
    fog = (msg and msg.fog) and 1 or 0,
  }
  if not x.init then
    for k, v in pairs(tgt) do x[k] = v end
    x.init = true
  else
    for k, v in pairs(tgt) do x[k] = x[k] + (v - x[k]) * a end
  end
  x.code = tonumber(msg and msg.code) or 0
  x.rate = rateNow                                            -- already smoothed by BeamNG.Earth (rainNow)
  -- puddle water: fills with ~8 min of rain, drains/evaporates over ~25 min (faster when warm and windy)
  local fill, drain = 480, 1500 / (1 + 0.03 * math.max(x.temp, 0) + 0.06 * x.wind)
  local tau = (rateNow > x.water) and fill or drain
  x.water = x.water + (rateNow - x.water) * (1 - math.exp(-dt / tau))
  return x
end

-- 0..1: how much the sun is up (BeamNG's clock: 0 = noon, 0.5 = midnight)
local function sunUp()
  local env = rawget(_G, 'core_environment')
  if not (env and type(env.getTimeOfDay) == 'function') then return 0.5 end
  local ok, tod = pcall(env.getTimeOfDay)
  local t = ok and type(tod) == 'table' and tonumber(tod.time) or nil
  if not t then return 0.5 end
  return clamp(math.cos(2 * math.pi * t) / 0.5, 0, 1)
end

local function isSnowCode(code) return (code >= 71 and code <= 77) or code == 85 or code == 86 end
local function isConvective(code) return (code >= 80 and code <= 82) or code >= 95 end
local function isDrizzle(code) return code >= 51 and code <= 57 end

-- The values ForeverWEATHER uses. p = the player's own values (their taste); rain = the rain share to draw.
local function weatherValues(p, x, rain)
  local v = { rain = rain, followWeather = false, autoClouds = false, precipitation = false }
  if not cfg.weatherLook then return v end
  local R = math.max(x.rate, 0)                                  -- mm/h now
  local W = math.max(x.water, 0)                                 -- mm/h, slow memory (puddles)
  local heavy = clamp(R / 10, 0, 1)

  -- drop size (mm): Marshall-Palmer median volume diameter ~0.9 R^0.21, a little larger on screen; drizzle is fine,
  -- showers and thunderstorms coarse (hail codes 96 / 99 too)
  local d = 1.2 * (math.max(R, 0.05) ^ 0.21)
  if isDrizzle(x.code) then d = math.min(d, 0.75) end
  if isConvective(x.code) then d = d * 1.2 end
  v.rainDropSize = clamp(d, 0.5, 3.0)

  -- wetting and drying: heavy rain soaks the road in seconds; drying takes the real time it takes (warm, windy and sunny
  -- dries fastest; a cold, calm, overcast night keeps the road wet for an hour)
  v.wetUpTime = clamp(45 / (1 + 1.5 * R), 6, 60)
  local warm = clamp(1.6 - 0.035 * x.temp, 0.45, 2.0)
  local windK = 1 / (1 + 0.08 * x.wind)
  local sunK = 1 - 0.45 * sunUp() * (1 - clamp(x.cover, 0, 1))
  local humid = 1 + 0.6 * clamp(x.fog + (x.vis < 2000 and 0.5 or 0), 0, 1)
  v.dryTime = clamp(28 * warm * windK * sunK * humid, 4, 60)

  -- puddles: the player's coverage at about 3 mm/h of sustained rain, fewer in drizzle, more in a long downpour
  local covK = clamp(0.35 + 0.33 * (math.log(1 + W) / math.log(2)), 0.3, 1.8)
  v.puddleCoverage = clamp((p.puddleCoverage or 0.30) * covK, 0, 0.85)
  -- rain ripples on the puddles: impacts (rate) plus a ruffle from the gusts; the player's slider scales it
  local rip = clamp(0.12 + 0.26 * (math.log(1 + R) / math.log(2)) + 0.02 * math.min(x.gust, 15), 0.08, 1.2)
  v.puddleRipple = clamp(rip * ((p.puddleRipple or 0.5) / 0.5), 0, 2)

  -- road film: drizzle stays damp asphalt, a downpour makes it smoother, glossier and floods it
  v.roadRoughness = clamp((p.roadRoughness or 0.42) * (1.12 - 0.27 * heavy), 0.05, 1)
  v.roadReflection = clamp((p.roadReflection or 0.70) * (0.92 + 0.16 * heavy), 0, 1)
  v.roadFlood = clamp((p.roadFlood or 0.15) * (0.35 + W / 4.5), 0, 1)

  -- tyre spray follows the water on the road
  v.splashIntensity = clamp((p.splashIntensity or 0.30) * clamp(0.6 + 0.13 * W, 0.6, 1.7), 0, 2)
  return v
end

-- 1.6 how damp the air is (0..1) for ForeverWEATHER's glass fog and body mist: fog, poor visibility, drizzle; a little
-- more in the cold (the glass and the bodywork cool below the dew point sooner)
local function humidityFor(x)
  local h = 0
  if (x.fog or 0) > 0 then h = math.max(h, 0.85 * clamp(x.fog, 0, 1)) end
  if (x.vis or 20000) < 5000 then h = math.max(h, 0.8 * clamp((5000 - x.vis) / 4000, 0, 1)) end
  if isDrizzle(x.code or 0) then h = math.max(h, 0.7) end
  if (x.temp or 12) < 8 then h = h * 1.15 end
  return clamp(h, 0, 1)
end

-- Snow: no rain to draw; above freezing the road is slushy-wet under it (a wet floor, no falling rain)
local function wetFloorFor(x)
  if x.snow > 0.05 and x.temp > -1.0 then return clamp(0.35 + 0.25 * clamp(x.snow, 0, 2), 0, 0.85) end
  return 0
end

local function valuesDiffer(a, b)
  if not a or not b then return true end
  for k, v in pairs(a) do
    local o = b[k]
    if type(v) == 'number' and type(o) == 'number' then
      if math.abs(v - o) > math.max(0.004, math.abs(v) * 0.01) then return true end
    elseif v ~= o then
      return true
    end
  end
  for k in pairs(b) do if a[k] == nil then return true end end
  return false
end

local function send(m, vals, opts, force)
  local diff = valuesDiffer(vals, st.sent) or valuesDiffer(opts, st.opts)
  local since = clock - st.lastSentAt
  if not force then
    if diff and since < SEND_MIN_S then return end    -- at most once a second
    if not diff and since < 5 then return end         -- unchanged: refreshed every 5 s
  end
  local ok, res, why = pcall(m.setExternalWeather, SRC, vals, opts)
  if not ok then
    warnOnce('setExternal', 'Rain Puddles setExternalWeather failed: ' .. tostring(res))
  elseif res == false then
    warnOnce('setExternal_busy', 'Rain Puddles refused the weather: ' .. tostring(why))
  else
    st.sent, st.opts, st.lastSentAt = vals, opts, clock
  end
end

------------------------------------------------------------------------------------------------------------------------
-- taking over and handing back

local function release(m, w, why)
  if st.engaged and m and rpHasApi(m) then pcall(m.clearExternalWeather, SRC) end
  restoreEarthRain(w)
  clearParticles()
  if st.engaged then log('I', TAG, 'handed back (' .. tostring(why) .. ')') end
  st.engaged, st.sent, st.opts, st.why = false, nil, nil, why
end

local function tick(dt)
  local w, m = earthExt(), rpExt()
  local onEarth = w ~= nil and isEarthLevel(w)
  if not (cfg.enabled and onEarth and m) then
    if st.engaged then
      release(m, w, not cfg.enabled and 'switched off' or (not onEarth and 'left the BeamNG.Earth map') or 'Rain Puddles unloaded')
    end
    if st.earthRainHidden then restoreEarthRain(w) end
    if scenetree.findObject(P_HEAVY) or scenetree.findObject(P_FINE) then clearParticles() end
    st.why = not cfg.enabled and 'switched off' or (not onEarth and 'not on the BeamNG.Earth map') or 'Rain Puddles not loaded'
    return
  end
  if not rpHasApi(m) then
    warnOnce('api', 'this Rain Puddles has no external weather API (1.0.2 or newer needed): the bridge waits')
    st.why = 'Rain Puddles too old'
    return
  end

  local okS, p = pcall(type(m.getPlayerSettings) == 'function' and m.getPlayerSettings or m.getSettings)
  if not okS or type(p) ~= 'table' then return end
  local live = m.getSettings()
  local rpOn = live.enabled == true
  local mode = earthMode(w)

  if not rpOn then
    if st.engaged then release(m, w, 'Rain Puddles switched off') end
    restoreEarthRain(w)
    st.why = 'Rain Puddles switched off'
    return
  end

  local opts = { label = LABEL }
  if mode ~= 'real' then
    -- BeamNG.Earth Manual: the player sets the weather, so ForeverWEATHER gets its own values back.
    -- (1.4: until 1.3.1 the bridge stayed engaged here only to keep Midnight's clock off; Midnight is gone.)
    if st.engaged then release(m, w, 'BeamNG.Earth weather on Manual') end
    st.mode, st.why = mode, 'BeamNG.Earth weather on Manual: the player sets it'
    restoreEarthRain(w)
    clearParticles()
    return
  end

  if not st.engaged then
    st.engaged = true
    log('I', TAG, 'BeamNG.Earth map: its real weather drives ForeverWEATHER')
    if not sessionNoted then
      sessionNoted = true
      toast('The real weather from BeamNG.Earth now drives ForeverWEATHER\'s rain, puddles and wet roads.')
    end
  end
  st.mode = mode

  local msg = earthMsg(w)
  local share = earthRainShare(w)
  local snowing = msg and (tonumber(msg.snowCmH) or 0) > 0.05 and isSnowCode(tonumber(msg.code) or 0)
  if snowing then share = 0 end
  local rate = (tonumber(w.RAIN_FULL_MMH) or 8) * share * share   -- rainNow = sqrt(mm/h / 8)
  local x = wxStep(w, msg, dt, rate)

  -- arriving where it really rains: the road there has been wet for a while (BeamNG.Earth fades its rain in after its
  -- start-up wait): wet the ground and fill the puddles for the real rain now
  local rainDraw = clamp(share * cfg.rainGain, 0, 1)
  if cfg.preWet and not st.preWetDone and clock - st.levelAt <= PREWET_WINDOW_S and msg then
    st.preWetDone = true
    local tgt = targetShare(w, msg)
    if tgt > 0.02 then
      rainDraw = math.max(rainDraw, clamp(tgt * cfg.rainGain, 0, 1))
      x.rate = math.max(x.rate, (tonumber(msg.rainMmH) or 0))
      x.water = math.max(x.water, (tonumber(msg.rainMmH) or 0))
      local vals = weatherValues(p, x, rainDraw)
      vals.rain = rainDraw
      opts.wetFloor = wetFloorFor(x)
      opts.humidity = humidityFor(x)                             -- 1.6 glass fog / body mist
      send(m, vals, opts, true)
      if type(m.snapWetness) == 'function' then pcall(m.snapWetness) end
      log('I', TAG, string.format('arrived in rain (%.2f mm/h): ground wetted', tonumber(msg.rainMmH) or 0))
    end
  end

  local vals = weatherValues(p, x, rainDraw)
  opts.wetFloor = wetFloorFor(x)
  opts.humidity = humidityFor(x)                                 -- 1.6 glass fog / body mist
  send(m, vals, opts, false)

  -- the player moved the rain slider: it follows the real rain here; say why once a map
  local have = tonumber(live.rain) or 0
  if st.sent and math.abs(have - (st.sent.rain or have)) > 0.02 and not st.handNoted then
    st.handNoted = true
    toast('Rain follows BeamNG.Earth\'s real weather on this map. Your own values are kept for later; set BeamNG.Earth\'s '
      .. 'weather to Manual (pause menu > BeamNG.Earth settings) to choose the weather yourself.', 'warning')
  end

  hideEarthRain(w)
  updateParticles(cfg.particles and p.precipitation == true, p, vals.rain)
  st.why = snowing and 'snow (BeamNG.Earth draws it)' or string.format('real weather: %.2f mm/h', x.rate)
end

local function resetLevelState(levelStart)
  st.rainObjId = nil
  st.earthRainHidden = false
  st.preWetDone = false
  st.handNoted = false
  st.levelAt = clock
  st.wx = nil
  local w = levelStart and earthExt() or nil
  st.rainNowAtStart = w and tonumber(w.rainNow) or nil
  st.rainNowLive = (st.rainNowAtStart == nil)
  pcache = {}
end

local function safeTick(dt)
  local ok, err = pcall(tick, dt or 0)
  if not ok then
    errors = errors + 1
    if errors <= 3 then log('E', TAG, 'update failed: ' .. tostring(err)) end
  end
end

------------------------------------------------------------------------------------------------------------------------
-- hooks

function M.onExtensionLoaded()
  st = newState()
  resetLevelState(false)
  loadCfg()
  pcall(oldJournalGiveBack, rpExt())
  log('I', TAG, 'v' .. VERSION .. ' loaded' .. (cfg.enabled and '' or ' (switched off)'))
  -- take over in this same call (a reload on the map must not give Rain Puddles a frame to write the clouds)
  safeTick(0)
end

function M.onExtensionUnloaded()
  local w, m = earthExt(), rpExt()
  release(m, w, 'unloaded')
  restoreEarthRain(w)
  clearParticles()
end

function M.onUpdate(dtReal)
  local dt = tonumber(dtReal) or 0
  clock = clock + dt
  -- BeamNG.Earth shows its rain again when its rain starts (setHidden on a change only): hide it the same frame
  if st.earthRainHidden and st.rainObjId then
    local o = scenetree.findObjectById(st.rainObjId)
    if o and isHiddenObj(o) == false then setHiddenObj(o, true) end
  end
  tickTimer = tickTimer + dt
  if tickTimer >= TICK_S then
    local step = tickTimer
    tickTimer = 0
    safeTick(step)
  end
end

-- a new level: take over at once, before Rain Puddles' first cloud or rain update on it
function M.onClientStartMission()
  resetLevelState(true)
  tickTimer = 0
  safeTick(0)
end

function M.onClientEndMission()
  resetLevelState(false)
end

------------------------------------------------------------------------------------------------------------------------
-- console API

function M.set(key, value)
  if defaults[key] == nil then return 'unknown setting: ' .. tostring(key) end
  if type(defaults[key]) == 'boolean' then
    value = (value == true or value == 'true' or value == 1)
  else
    value = tonumber(value)
    if value == nil then return key .. ' needs a number' end
    local r = ranges[key]
    if r then value = clamp(value, r[1], r[2]) end
  end
  cfg[key] = value
  saveCfg()
  tickTimer = 0
  st.sent = nil
  safeTick(0)
  return key .. ' = ' .. tostring(value)
end

function M.setEnabled(on) return M.set('enabled', on and true or false) end

function M.getSettings()
  local out = {}
  for k, v in pairs(cfg) do out[k] = v end
  return out
end

function M.status()
  local w, m = earthExt(), rpExt()
  local msg = w and earthMsg(w) or nil
  local o = (w and levelId()) and earthRainObject(w) or nil
  local x = st.wx
  local info = {
    version = VERSION,
    settings = M.getSettings(),
    level = levelId(),
    state = st.why,
    beamngEarth = w and {
      onItsMap = isEarthLevel(w), mode = earthMode(w), rainNow = w.rainNow,
      code = msg and msg.code, rainMmH = msg and msg.rainMmH, snowCmH = msg and msg.snowCmH,
      tempC = msg and (msg.tempC or msg.slTempC), windMs = msg and msg.wind and msg.wind.ms, visM = msg and msg.visM,
      rainObject = o and (tostring(objName(o)) .. ' #' .. tostring(objId(o)) .. (isHiddenObj(o) and ' (hidden)' or ' (shown)'))
        or 'not found',
    } or 'not loaded',
    smoothed = x and { rateMmH = x.rate, waterMmH = x.water, tempC = x.temp, windMs = x.wind, cover = x.cover } or nil,
    sent = st.sent,
    rainPuddles = m and { enabled = m.getSettings().enabled, external = type(m.getExternalWeather) == 'function'
      and m.getExternalWeather() or 'no API' } or 'not loaded',
    particleRain = { rain = scenetree.findObject(P_HEAVY) ~= nil, spray = scenetree.findObject(P_FINE) ~= nil },
  }
  local okD, text = pcall(dumps, info)
  log('I', TAG, 'status: ' .. (okD and text or tostring(info)))
  return info
end

return M
