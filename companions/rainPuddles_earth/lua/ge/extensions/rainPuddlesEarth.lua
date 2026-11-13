-- Rain Puddles x BeamNG.Earth (GE extension 'rainPuddlesEarth') 1.0.0
--
-- Companion for Rain Puddles 1.0 (extension 'rainPuddles') and BeamNG.Earth 1.8 (extension 'beamngEarth_weather') on
-- BeamNG.drive 0.40. On the BeamNG.Earth map, BeamNG.Earth keeps supplying the real weather (Open-Meteo, through its
-- companion server) and Rain Puddles draws the rain:
--   * the rain BeamNG.Earth shows right now (beamngEarth_weather.rainNow: its 0..1 share of the drop pool, already
--     smoothed, and 0 above the cloud base or in its Manual mode) drives Rain Puddles' 'rain' setting;
--   * BeamNG.Earth's own rain particles (the level's Precipitation object 'bngEarthRain') are hidden while Rain Puddles
--     is on, and shown again the way BeamNG.Earth wants them when Rain Puddles is switched off or unloaded, when the
--     map is left, and when this extension is switched off or unloaded;
--   * the falling rain is drawn here with Rain Puddles' own native-rain recipe (see "falling rain" below for why).
-- Only the public Lua of both mods is used; no file of either mod is changed. Everything stays inside this extension,
-- its two settings files and its two particle objects, so it can be bundled as it is (e.g. into a launcher).
--
-- Console (GE Lua):
--   rainPuddlesEarth.status()               what it does now (also written to the log)
--   rainPuddlesEarth.setEnabled(false)      hand everything back (saved)
--   rainPuddlesEarth.set('rainGain', 1.2)   settings: enabled, rainGain (0-3), preWet, particles (saved)

local M = {}

local TAG = 'rainPuddlesEarth'
local VERSION = '1.0.0'
local SETTINGS_FILE = '/settings/rainPuddles_earth.json'
local RESTORE_FILE = '/settings/rainPuddles_earth_restore.json'
local RP_SETTINGS_FILE = '/settings/rainPuddles.json'   -- only written when Rain Puddles is not loaded (see giveBack)

local RP_EXT = 'rainPuddles'
local EARTH_EXT = 'beamngEarth_weather'
local EARTH_LEVEL_DEFAULT = 'beamng_earth'   -- beamngEarth_weather.LEVEL_ID
local EARTH_RAIN_DEFAULT = 'bngEarthRain'    -- beamngEarth_weather.RAIN_NAME

local TICK_S = 0.25           -- main update
local SEND_MIN_S = 1.0        -- Rain Puddles' rain is written at most once a second when it moved by SEND_EPS
local SEND_EPS = 0.015        -- (every write is saved to its settings file and sent to its UI)
local SEND_SETTLE_S = 4.0     -- smaller differences are written after this long
local PREWET_WINDOW_S = 90    -- the first weather message this soon after arriving wets the ground at once
local PREWET_MIN_MMH = 0.05   -- BeamNG.Earth's own "it rains" threshold (weather.lua precipPct)
local GIVEBACK_RETRY_S = 5    -- a give-back without Rain Puddles (its settings file) is retried this often

-- Rain Puddles settings this extension holds while it runs on a BeamNG.Earth map (the player's own values are given
-- back afterwards):
--   followWeather  Rain Puddles would read the rain from the level's Precipitation objects' numDrops. BeamNG.Earth
--                  sets a fixed pool once and controls the amount with setPercentage / setHidden, so that reading
--                  is wrong (0, or a constant ~0.6 once it has rained or snowed).
--   autoClouds     Rain Puddles would write the cloud cover (core_environment.setCloudCover). BeamNG.Earth takes any
--                  weather change by someone else for the player taking over: its whole real weather (clouds, fog,
--                  wind, rain, temperature) switches to Manual and that is saved in its settings.
--   precipitation  Rain Puddles would take over the nearest Precipitation object of the level: one of BeamNG.Earth's
--                  (its rain, hidden here, or its snow). The falling rain is drawn here instead (see below).
local GUARDS = { followWeather = false, autoClouds = false, precipitation = false }
local GUARD_KEYS = { 'followWeather', 'autoClouds', 'precipitation' }

local defaults = {
  enabled = true,
  rainGain = 1.0,     -- Rain Puddles' rain = BeamNG.Earth's rain share x this
  preWet = true,      -- arriving where it really rains, the ground is wet at once
  particles = true,   -- draw the falling rain (Rain Puddles' native-rain recipe) while its "Native rain" was on
}
local ranges = { rainGain = { 0, 3 } }

local cfg = {}
local journal = { active = false, guards = {}, rain = nil }   -- the player's Rain Puddles values (also on disk)
local clock, tickTimer, giveBackAt = 0, 0, -1e9

local function newState()
  return { engaged = false, driving = false, lastSent = nil, lastSentAt = -1e9, levelAt = 0, rainObjId = nil,
           earthRainHidden = false, preWetDone = false, handNoted = false, guardNoted = false,
           rainNowAtStart = nil, rainNowLive = true }
end
local st = newState()
local warned, errors = {}, 0
local sessionNoted = false

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
    pcall(gh.trigger, 'toastrMsg', { type = kind or 'info', title = 'Rain Puddles x BeamNG.Earth', msg = msg })
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

-- scene object access, all guarded (objects can vanish with the level)
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
  if type(m) == 'table' and type(m.setSetting) == 'function' and type(m.getSettings) == 'function' then return m end
  return nil
end

local function earthExt()
  local w = rawget(_G, EARTH_EXT)
  if type(w) == 'table' then return w end
  return nil
end

local function rpSettings(m)
  local ok, s = pcall(m.getSettings)
  if ok and type(s) == 'table' then return s end
  warnOnce('getSettings', 'Rain Puddles getSettings() failed: ' .. tostring(s))
  return nil
end

local function rpSet(m, key, value)
  local ok, err = pcall(m.setSetting, key, value)
  if not ok then warnOnce('set_' .. key, 'Rain Puddles setSetting(' .. key .. ') failed: ' .. tostring(err)) end
  return ok
end

local function isEarthLevel(w)
  local id = levelId()
  if not id then return false end
  local want = (type(w.LEVEL_ID) == 'string' and w.LEVEL_ID ~= '') and w.LEVEL_ID or EARTH_LEVEL_DEFAULT
  return id == want
end

-- 'real' (BeamNG.Earth drives the weather) or 'manual' (the player's own controls)
local function earthMode(w)
  if type(w.getMode) ~= 'function' then return 'real' end
  local ok, mode = pcall(w.getMode)
  return ok and mode or nil
end

-- The rain BeamNG.Earth shows now, 0..1 (its share of the drop pool: sqrt(mm/h / 8), smoothed over a minute).
-- rainNow is a module field that survives a level load: until BeamNG.Earth's first weather update on the new map
-- (after its start-up wait, GRACE_S) it still holds the last map's value, and BeamNG.Earth shows no rain meanwhile.
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

-- The share BeamNG.Earth is heading for at this place (its latest weather message), and the message.
local function earthTargetShare(w)
  if type(w.current) ~= 'function' then return nil end
  local ok, msg = pcall(w.current)
  if not ok or type(msg) ~= 'table' then return nil end
  local rate = tonumber(msg.rainMmH) or 0
  if rate <= PREWET_MIN_MMH then return 0, msg end
  local full = tonumber(w.RAIN_FULL_MMH) or 8
  local pct = nil
  if type(w.precipPct) == 'function' then
    local okP, p = pcall(w.precipPct, rate, full)
    pct = okP and tonumber(p) or nil
  end
  pct = pct or clamp(math.sqrt(rate / full), 0.08, 1)
  return clamp(pct, 0, 1), msg
end

------------------------------------------------------------------------------------------------------------------------
-- settings and the give-back journal

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

-- The journal holds the player's own Rain Puddles values while this extension holds them, on disk as well, so they
-- come back even after a crash or when Rain Puddles was unloaded first.
local function loadJournal()
  journal = { active = false, guards = {}, rain = nil }
  local data = readJson(RESTORE_FILE)
  if not (data and data.active == true) then return end
  journal.active = true
  if type(data.guards) == 'table' then
    for _, k in ipairs(GUARD_KEYS) do
      if type(data.guards[k]) == 'boolean' then journal.guards[k] = data.guards[k] end
    end
  end
  journal.rain = tonumber(data.rain)
end

local function saveJournal()
  writeJson(RESTORE_FILE, { active = journal.active, guards = journal.guards, rain = journal.rain, version = VERSION,
    note = 'Rain Puddles settings that rainPuddlesEarth gives back after a BeamNG.Earth session' })
end

-- Puts the player's own values back: through Rain Puddles' API, or into its settings file while it is not loaded (the
-- file is what it reads when it loads). true when nothing is left to give back.
local function giveBack(m)
  if not journal.active then return true end
  if m then
    local s = rpSettings(m)
    for _, k in ipairs(GUARD_KEYS) do
      local v = journal.guards[k]
      if v ~= nil and (not s or s[k] ~= v) then rpSet(m, k, v) end
    end
    if journal.rain ~= nil and (not s or math.abs((tonumber(s.rain) or 0) - journal.rain) > 1e-6) then
      rpSet(m, 'rain', journal.rain)
    end
    if type(m.save) == 'function' then pcall(m.save) end
  else
    local data = readJson(RP_SETTINGS_FILE)
    if not data then return false end
    for _, k in ipairs(GUARD_KEYS) do
      if journal.guards[k] ~= nil then data[k] = journal.guards[k] end
    end
    if journal.rain ~= nil then data.rain = journal.rain end
    if not writeJson(RP_SETTINGS_FILE, data) then return false end
  end
  journal = { active = false, guards = {}, rain = nil }
  saveJournal()
  log('I', TAG, 'the player\'s Rain Puddles settings are back' .. (m and '' or ' (written to its settings file)'))
  return true
end

------------------------------------------------------------------------------------------------------------------------
-- BeamNG.Earth's own rain particles

-- The level's Precipitation object named RAIN_NAME. Looked up by class as well as by name: BeamNG.Earth 1.8.2 also
-- registers its rain sound emitter (ambience.lua) as 'bngEarthRain', and the name then finds whichever object came
-- last, so the Weather group is searched when the name gives something else.
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
  local g = scenetree.findObject('Weather')
  if not g then return nil end
  local okN, n = pcall(function() return g:size() end)
  local byAt = okN and tonumber(n) ~= nil
  if not byAt then okN, n = pcall(function() return g:getCount() end) end
  n = okN and tonumber(n) or 0
  for i = 0, n - 1 do
    local okC, c = pcall(function() if byAt then return g:at(i) end return g:getObject(i) end)
    if okC and c and className(c) == 'Precipitation' and objName(c) == name then
      st.rainObjId = objId(c)
      return c
    end
  end
  return nil
end

-- What BeamNG.Earth itself would show: its rain while it rains in its Real mode (weather.lua drivePrecip).
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
-- falling rain
-- Rain Puddles draws its native rain on its own Precipitation objects only on levels that have none; otherwise it takes
-- over the nearest one of the level. On BeamNG.Earth that would be BeamNG.Earth's rain or snow object, so its
-- 'precipitation' setting is held off here and the same rain is drawn with the recipe of Rain Puddles 1.0
-- (rainPuddles.lua createManagedPrecip / updatePrecipitation: datablocks, sizes, boxes and counts by rain amount, its
-- 'Maximum rain particles' and 'precipFollow'). Own object names, so neither mod touches them.

local P_HEAVY, P_FINE = 'RainPuddlesEarth_Rain', 'RainPuddlesEarth_Spray'
local pcache = {}   -- [name] = last written values

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
    warnOnce('db_' .. dataBlock, 'falling rain skipped: datablock "' .. dataBlock .. '" not available')
    return nil
  end
  local okC, obj = pcall(createObject, 'Precipitation')
  if not okC or not obj then
    warnOnce('precip_class', 'falling rain skipped: could not create a Precipitation object')
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
    warnOnce('precip_reg', 'falling rain skipped: could not register ' .. name)
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

-- One object: drop count, box and drop size (when the rain moved), and the box over the camera.
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
  local useFine = rain >= 0.52

  local heavy = scenetree.findObject(P_HEAVY) or createPrecip(P_HEAVY, 'rain_medium')
  if heavy then
    shapePrecip(P_HEAVY, heavy, round(maxDrops * 0.68 * (rain ^ 1.15)), rain,
      { 100 + 80 * rain, 60 + 55 * rain }, { 0.05 + 0.07 * rain, 0.12 + 0.16 * rain }, follow, cx, cy, cz, 24.0)
  end
  if useFine then
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
-- driving Rain Puddles' rain

local function sendRain(m, v)
  if rpSet(m, 'rain', v) then st.lastSent, st.lastSentAt = v, clock end
end

local function startDriving(m, s)
  if journal.rain == nil then
    journal.rain = tonumber(s.rain)
    saveJournal()
  end
  st.driving = true
  st.lastSent, st.lastSentAt = nil, -1e9
end

-- The player's own rain back (kept in the journal while Rain Puddles is not loaded).
local function stopDriving(m)
  st.driving = false
  st.lastSent = nil
  if not m then return end
  if journal.rain ~= nil then
    rpSet(m, 'rain', journal.rain)
    journal.rain = nil
    saveJournal()
  end
end

local function driveRain(m, s, w)
  local have = tonumber(s.rain) or 0
  -- changed by hand (the Rain Puddles panel, a preset, the console): it goes back to the real rain; say why, once a map
  if st.lastSent and math.abs(have - st.lastSent) > 0.005 and not st.handNoted then
    st.handNoted = true
    toast('Rain Puddles follows BeamNG.Earth\'s real rain on this map. Set BeamNG.Earth\'s weather to Manual '
      .. '(pause menu > BeamNG.Earth settings) to choose the rain yourself.', 'warning')
  end

  -- Arriving where it really rains: BeamNG.Earth fades its rain in over about a minute (after a 20 s start-up wait),
  -- but the road there has been wet for a while. Wet the ground for the real rain now; the rain itself then follows
  -- BeamNG.Earth from the next update, and the ground dries only slowly ('Drying time') meanwhile.
  if cfg.preWet and not st.preWetDone and clock - st.levelAt <= PREWET_WINDOW_S then
    local target, msg = earthTargetShare(w)
    if target ~= nil then
      st.preWetDone = true
      local v = clamp(target * cfg.rainGain, 0, 1)
      if v > 0.02 and v > have + 0.01 and type(m.snapWetness) == 'function' then
        sendRain(m, v)
        pcall(m.snapWetness)
        log('I', TAG, string.format('arrived in rain (%.2f mm/h): ground wetted for rain %.2f',
          tonumber(msg and msg.rainMmH) or 0, v))
        return
      end
    end
  end

  local want = clamp(earthRainShare(w) * cfg.rainGain, 0, 1)
  want = math.floor(want * 1000 + 0.5) / 1000
  local diff = math.abs(want - have)
  local since = clock - st.lastSentAt
  if (want == 0 and have > 0) or (diff >= SEND_EPS and since >= SEND_MIN_S) or (diff > 0.0005 and since >= SEND_SETTLE_S) then
    sendRain(m, want)
  end
end

------------------------------------------------------------------------------------------------------------------------
-- taking over and handing back

local function engage(m, s)
  if not journal.active then
    journal.active = true
    journal.guards, journal.rain = {}, nil
    for _, k in ipairs(GUARD_KEYS) do
      if type(s[k]) == 'boolean' then journal.guards[k] = s[k] end
    end
    saveJournal()
  end
  for _, k in ipairs(GUARD_KEYS) do
    if s[k] ~= nil and s[k] ~= GUARDS[k] then rpSet(m, k, GUARDS[k]) end
  end
  st.engaged = true
  log('I', TAG, string.format('BeamNG.Earth map: Rain Puddles draws the rain (player values kept: followWeather=%s, '
    .. 'autoClouds=%s, precipitation=%s)', tostring(journal.guards.followWeather), tostring(journal.guards.autoClouds),
    tostring(journal.guards.precipitation)))
  if not sessionNoted then
    sessionNoted = true
    toast('Rain Puddles draws the rain on this map, from BeamNG.Earth\'s real weather.')
  end
end

-- A held setting switched by the player (the Rain Puddles panel) is their choice for after this map; it stays held here.
local function holdGuards(m, s)
  local changed = false
  for _, k in ipairs(GUARD_KEYS) do
    if s[k] ~= nil and s[k] ~= GUARDS[k] then
      journal.guards[k] = s[k]
      changed = true
      rpSet(m, k, GUARDS[k])
    end
  end
  if changed then
    saveJournal()
    if not st.guardNoted then
      st.guardNoted = true
      toast('On BeamNG.Earth maps Rain Puddles\' clouds, weather following and native rain stay off (the falling rain '
        .. 'is drawn by this companion). Your choice is used again on other maps.')
    end
  end
end

local function disengage(w, m, why)
  if st.driving then stopDriving(m) end
  restoreEarthRain(w)
  clearParticles()
  if m then giveBack(m) end   -- without Rain Puddles the journal waits (see tick / onExtensionUnloaded)
  st.engaged = false
  log('I', TAG, 'handed back (' .. tostring(why) .. ')')
end

------------------------------------------------------------------------------------------------------------------------
-- update

local function tick()
  local w, m = earthExt(), rpExt()
  local onEarth = w ~= nil and isEarthLevel(w)

  if not (cfg.enabled and onEarth and m) then
    if st.engaged then
      disengage(w, m, not cfg.enabled and 'switched off' or (not onEarth and 'left the BeamNG.Earth map')
        or 'Rain Puddles unloaded')
    end
    if st.earthRainHidden then restoreEarthRain(w) end
    if scenetree.findObject(P_HEAVY) or scenetree.findObject(P_FINE) then clearParticles() end
    -- values still held from an earlier session (a crash, or Rain Puddles unloaded first): give them back, unless
    -- this is a BeamNG.Earth map that only waits for Rain Puddles to come back
    if journal.active and not (cfg.enabled and onEarth) and (m or clock - giveBackAt >= GIVEBACK_RETRY_S) then
      giveBackAt = clock
      giveBack(m)
    end
    return
  end

  local s = rpSettings(m)
  if not s then return end
  if not st.engaged then
    engage(m, s)
    s = rpSettings(m) or s
  end
  holdGuards(m, s)

  local rpOn = s.enabled == true
  if rpOn and earthMode(w) == 'real' then
    if not st.driving then startDriving(m, s) end
    driveRain(m, s, w)
  elseif st.driving then
    stopDriving(m)
  end

  if rpOn then hideEarthRain(w) else restoreEarthRain(w) end

  local rain = s.rain
  if st.driving and st.lastSent then rain = st.lastSent end
  updateParticles(rpOn and cfg.particles and journal.guards.precipitation ~= false, s, rain)
end

-- levelStart: a level is starting, so BeamNG.Earth's rainNow may still be the last map's (see earthRainShare). Not on
-- an extension (re)load in the middle of a map: there it is live.
local function resetLevelState(levelStart)
  st.rainObjId = nil
  st.earthRainHidden = false
  st.preWetDone = false
  st.handNoted = false
  st.guardNoted = false
  st.levelAt = clock
  local w = levelStart and earthExt() or nil
  st.rainNowAtStart = w and tonumber(w.rainNow) or nil
  st.rainNowLive = (st.rainNowAtStart == nil)
  pcache = {}
end

local function safeTick()
  local ok, err = pcall(tick)
  if not ok then
    errors = errors + 1
    if errors <= 3 then log('E', TAG, 'update failed: ' .. tostring(err)) end
  end
end

------------------------------------------------------------------------------------------------------------------------
-- hooks

function M.onExtensionLoaded()
  st = newState()
  resetLevelState()
  loadCfg()
  loadJournal()
  log('I', TAG, 'v' .. VERSION .. ' loaded' .. (cfg.enabled and '' or ' (switched off)')
    .. (journal.active and '; Rain Puddles settings held from an earlier BeamNG.Earth session will be given back' or ''))
  -- Take over in this same call: on a reload on the BeamNG.Earth map the old instance has just given the player's
  -- values back (clouds included), and one Rain Puddles cloud update before the next tick is enough for BeamNG.Earth
  -- to switch its real weather to Manual (seen in game).
  safeTick()
end

function M.onExtensionUnloaded()
  local w, m = earthExt(), rpExt()
  if st.engaged then disengage(w, m, 'unloaded') end
  restoreEarthRain(w)
  clearParticles()
  if journal.active then giveBack(m) end
end

function M.onUpdate(dtReal)
  local dt = tonumber(dtReal) or 0
  clock = clock + dt
  -- BeamNG.Earth shows its rain again when its rain starts (setHidden on a change only): hide it the same frame
  if st.earthRainHidden and st.rainObjId then
    local o = scenetree.findObjectById(st.rainObjId)
    if o and isHiddenObj(o) == false then setHiddenObj(o, true) end
  end
  -- Rain Puddles' automatic clouds switched on again (its panel, its reset): held off the same frame, before its next
  -- cloud update writes the cover and BeamNG.Earth takes that for the player changing the weather
  if st.engaged then
    local m = rpExt()
    local s = m and rpSettings(m)
    if s and s.autoClouds == true then pcall(holdGuards, m, s) end
  end
  tickTimer = tickTimer + dt
  if tickTimer >= TICK_S then
    tickTimer = 0
    safeTick()
  end
end

-- a new level: take over at once, before Rain Puddles' first cloud or rain update on it
function M.onClientStartMission()
  resetLevelState(true)
  tickTimer = 0
  safeTick()
end

function M.onClientEndMission()
  -- the level's objects go with it; the hand-back runs on the next update (the next level's or the menu's)
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
  safeTick()   -- applied now
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
  local s = m and rpSettings(m) or nil
  local msg = nil
  if w and type(w.current) == 'function' then
    local ok, cur = pcall(w.current)
    if ok and type(cur) == 'table' then msg = cur end
  end
  local o = (w and levelId()) and earthRainObject(w) or nil
  local info = {
    version = VERSION,
    settings = M.getSettings(),
    level = levelId(),
    beamngEarth = w and {
      onItsMap = isEarthLevel(w), mode = earthMode(w), rainNow = w.rainNow,
      rainMmH = msg and msg.rainMmH, snowCmH = msg and msg.snowCmH, code = msg and msg.code,
      rainObject = o and (tostring(objName(o)) .. ' #' .. tostring(objId(o))
        .. (isHiddenObj(o) and ' (hidden)' or ' (shown)')) or 'not found',
    } or 'not loaded',
    rainPuddles = m and s and {
      enabled = s.enabled, rain = s.rain, followWeather = s.followWeather, autoClouds = s.autoClouds,
      precipitation = s.precipitation,
    } or 'not loaded',
    engaged = st.engaged, driving = st.driving, lastSent = st.lastSent, earthRainHidden = st.earthRainHidden,
    fallingRain = { rain = scenetree.findObject(P_HEAVY) ~= nil, spray = scenetree.findObject(P_FINE) ~= nil },
    heldForPlayer = journal,
  }
  local okD, text = pcall(dumps, info)
  log('I', TAG, 'status: ' .. (okD and text or tostring(info)))
  return info
end

return M
