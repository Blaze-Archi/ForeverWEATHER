-- ForeverWEATHER 1.6: rain you can hear (rainPuddlesAudio).
--
-- Four looping layers played through the game's own sound engine (FMOD) as 2D SFX emitters, mixed by how hard it rains
-- and by where the listener (the camera) is:
--   light    sparse drops ticking on the ground, a soft hiss               open air, light rain
--   heavy    a downpour's roar                                            open air, heavy rain
--   muffled  the rain heard through a roof, a bridge deck or a car body    sheltered, and from the driver's seat
--   roof     drops drumming on the car's roof, heard from inside            in-car views, the car standing in the rain
--
-- Shelter detection casts no rays of its own: five times a second it asks the main extension (getAudioState) for the
-- exposure computed from the shelter grid the falling rain and the dry ground already keep (13 x 13 upward casts 4 m
-- apart around the camera, a few per frame, each cell cached for up to 30 s; three casts per cell, two must agree, so a
-- lamp post or a sign is no roof), whether the camera is in the cockpit and whether the player's car stands under a roof.
-- Between those samples the volumes glide (about a quarter of a second), so driving into a tunnel the open rain fades
-- over a car length, the muffled layer takes over and then goes too; leaving it, the roar comes back.
--
-- The loops are synthesised by tools/gen_rain_audio.py (no recordings, nothing taken from anywhere). Any layer can be
-- replaced by an FMOD Studio event or another file from the console, e.g.
--   extensions.rainPuddlesAudio.setLayerSound('heavy', 'event:>Some>Event')
-- Settings (in the main extension): rainAudio (on / off), rainAudioVolume (0..1.5).
-- Console: extensions.rainPuddlesAudio.getStatus()

local M = {}

local TAG = 'rainPuddlesAudio'
local DIR = '/art/sound/rainPuddles/'
local LAYERS = {
  { key = 'light', file = DIR .. 'rain_light.ogg' },
  { key = 'heavy', file = DIR .. 'rain_heavy.ogg' },
  { key = 'muffled', file = DIR .. 'rain_muffled.ogg' },
  { key = 'roof', file = DIR .. 'rain_roof.ogg' },
}
local SAMPLE_EVERY = 0.2      -- s between samples of the main extension's state (the shelter grid behind it is cached)
local GLIDE = 0.25            -- s, how fast a layer's volume follows its target
local IDLE_FREE = 4.0         -- s of silence after which the emitters are deleted (no FMOD voices while it is dry)

local st = {
  T = 0, sampleAt = -1e9, checkAt = -1e9, quietSince = nil,
  src = nil, failed = false, failNote = nil, warned = {},
  em = {}, cur = {}, tgt = {}, sent = {},
  open = 1, inCar = 0, carOpen = 1,
}

local function clamp(v, lo, hi)
  if v ~= v then return lo end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function smoothstep(a, b, x)
  local t = clamp((x - a) / (b - a), 0, 1)
  return t * t * (3 - 2 * t)
end

local function warnOnce(key, msg)
  if not st.warned[key] then
    st.warned[key] = true
    log('W', TAG, msg)
  end
end

local function objName(key) return 'RainPuddles_RainSfx_' .. key end

local function deleteLayer(key)
  local o = scenetree.findObject(objName(key))
  if o then pcall(function() o:delete() end) end
  st.em[key], st.sent[key] = nil, nil
end

local function deleteAll()
  for _, L in ipairs(LAYERS) do deleteLayer(L.key) end
  for _, L in ipairs(LAYERS) do st.cur[L.key] = 0 end
end

-- one looping 2D emitter, silent at first (the mix fades it in)
local function createLayer(L)
  deleteLayer(L.key)
  local ok, res = pcall(function()
    local o = createObject('SFXEmitter')
    if not o then error('createObject returned nothing') end
    local function f(k, v) pcall(function() o:setField(k, 0, tostring(v)) end) end
    f('fileName', L.file)
    f('is3D', 0)
    f('isLooping', 1)
    f('isStreaming', 0)
    f('playOnAdd', 1)
    f('volume', 0)
    f('fadeInTime', 0.3)
    f('fadeOutTime', 0.3)
    o:registerObject(objName(L.key))
    -- the level owns it: it goes with the level (and is made again for the next one)
    local mc = scenetree.findObject('MissionCleanup')
    if mc then pcall(function() mc:addObject(o) end) end
    return o
  end)
  if not ok or not res then return nil, tostring(res) end
  st.em[L.key], st.sent[L.key] = res, 0
  return res
end

-- the volume of a layer, on the playing source when the build exposes it, else through the emitter's field
local function sendVolume(key, v)
  local o = st.em[key]
  if not o then return end
  local last = st.sent[key]
  if last and math.abs(v - last) < 0.003 and not (v == 0 and last ~= 0) then return end
  st.sent[key] = v
  local ok, err = pcall(function()
    local src = nil
    pcall(function() src = o:getSource() end)
    if src then
      local okS = pcall(function() src:setVolume(v) end)
      if okS then return end
    end
    o:setField('volume', 0, string.format('%.4f', v))
    pcall(function() o:postApply() end)        -- (applies a changed field to the playing sound)
  end)
  if not ok then warnOnce('vol_' .. key, 'could not set the volume of the ' .. key .. ' rain layer: ' .. tostring(err)) end
end

-- the emitters exist while some layer should be heard; a level change takes them away, so they are checked now and then
local function ensureLayers()
  if st.failed then return false end
  if st.T - st.checkAt < 2.0 and next(st.em) then return true end
  st.checkAt = st.T
  for _, L in ipairs(LAYERS) do
    local o = st.em[L.key]
    if not (o and scenetree.findObject(objName(L.key))) then
      local made, why = createLayer(L)
      if not made then
        st.failed, st.failNote = true, why
        log('W', TAG, 'rain sound off: could not create a sound emitter (' .. tostring(why) .. ')')
        deleteAll()
        return false
      end
    end
  end
  return true
end

-- the main extension's state, five times a second
local function sample()
  st.sampleAt = st.T
  st.src = nil
  local main = extensions and extensions.rainPuddles
  if main and type(main.getAudioState) == 'function' then
    local ok, s = pcall(main.getAudioState)
    if ok and type(s) == 'table' then st.src = s end
  end
end

-- target volume of every layer
local function mix()
  local s = st.src
  for _, L in ipairs(LAYERS) do st.tgt[L.key] = 0 end
  -- nothing until the shelter grid around the camera is known (no burst of open rain at the start of a level in a tunnel)
  if not (s and s.on and s.live and s.gridReady) then return end
  local rain = clamp(tonumber(s.rain) or 0, 0, 1)
  if rain < 0.005 then return end
  local vol = clamp(tonumber(s.volume) or 0.8, 0, 1.5)
  local loud = rain ^ 0.6                                   -- loudness follows the rain the way the ear hears it
  local heavyK = smoothstep(0.3, 0.85, rain)
  local open, inCar, carOpen = st.open, st.inCar, st.carOpen
  local outside = 1 - inCar
  -- from the seat the car body lets only a little of the open rain's highs through; the rest arrives muffled
  local through = outside + inCar * 0.16
  -- driving into the rain: more drops on the roof and the windshield
  local drive = 1 + 0.4 * clamp((tonumber(s.speed) or 0) / 30, 0, 1)
  st.tgt.light = vol * loud * (1 - heavyK) * open * through
  st.tgt.heavy = vol * loud * heavyK * open * through * 0.9
  -- sheltered outside (under a bridge, at a tunnel portal): the rain still falls on the open part around, heard muffled
  -- (most halfway between open and covered; deep in a tunnel little of it); from the seat: the outside rain through the
  -- body, less of it under a roof
  st.tgt.muffled = vol * loud * (outside * 1.2 * open * (1 - open) + inCar * (0.1 + 0.6 * open))
  st.tgt.roof = vol * (rain ^ 0.75) * inCar * carOpen * 0.7 * drive
end

local function onUpdate(dtReal)
  local dt = math.max(tonumber(dtReal) or 0, 0)
  st.T = st.T + dt
  if st.T - st.sampleAt >= SAMPLE_EVERY then sample() end
  local s = st.src
  -- the listener's situation glides: shelter over a third of a second, in / out of the car quicker (a camera switch)
  if s then
    local kOpen = 1 - math.exp(-dt / 0.35)
    st.open = st.open + (clamp(tonumber(s.exposure) or 1, 0, 1) - st.open) * kOpen
    st.carOpen = st.carOpen + (clamp(tonumber(s.carOpen) or 1, 0, 1) - st.carOpen) * kOpen
    st.inCar = st.inCar + ((s.cockpit and 1 or 0) - st.inCar) * (1 - math.exp(-dt / 0.12))
  end
  mix()
  local anyTgt, anyCur = false, false
  for _, L in ipairs(LAYERS) do
    if (st.tgt[L.key] or 0) > 0.002 then anyTgt = true end
  end
  if anyTgt then
    st.quietSince = nil
    if not ensureLayers() then return end
  end
  local k = 1 - math.exp(-dt / GLIDE)
  for _, L in ipairs(LAYERS) do
    local c = st.cur[L.key] or 0
    c = c + ((st.tgt[L.key] or 0) - c) * k
    if c < 1e-4 and (st.tgt[L.key] or 0) <= 0 then c = 0 end
    st.cur[L.key] = c
    if c > 0 then anyCur = true end
    sendVolume(L.key, c)
  end
  -- dry for a while: free the emitters (and their voices) until it rains again
  if not anyTgt and not anyCur and next(st.em) then
    st.quietSince = st.quietSince or st.T
    if st.T - st.quietSince > IDLE_FREE then deleteAll() end
  end
end

local function onExtensionUnloaded()
  deleteAll()
end

-- a level ends: its emitters go with it (they are made again when it rains in the next one)
local function onClientEndMission()
  st.em, st.sent = {}, {}
  for _, L in ipairs(LAYERS) do st.cur[L.key] = 0 end
end

M.onUpdate = onUpdate
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientEndMission = onClientEndMission

-- Console: extensions.rainPuddlesAudio.setLayerSound('heavy', 'event:>...' or '/art/sound/...ogg') - use another sound for a
-- layer (an FMOD Studio event of the game or another mod, or a file); nil = back to the mod's own loop
M.setLayerSound = function(key, path)
  for _, L in ipairs(LAYERS) do
    if L.key == key then
      L.file = (type(path) == 'string' and path ~= '') and path or (DIR .. 'rain_' .. key .. '.ogg')
      deleteLayer(key)
      st.checkAt = -1e9
      log('I', TAG, 'rain layer ' .. key .. ' now plays ' .. L.file)
      return true
    end
  end
  return false
end

-- Console: extensions.rainPuddlesAudio.reload() - try again after a failure (e.g. once the game's sound came back)
M.reload = function()
  st.failed, st.failNote = false, nil
  deleteAll()
  st.checkAt = -1e9
end

-- Diagnostics (the settings panel shows them): the layers' volumes now, the listener's exposure, what failed
M.getStatus = function()
  local layers = {}
  for _, L in ipairs(LAYERS) do layers[L.key] = math.floor((st.cur[L.key] or 0) * 1000 + 0.5) / 1000 end
  return { playing = next(st.em) ~= nil, failed = st.failed, note = st.failNote, layers = layers,
           exposure = math.floor(st.open * 100 + 0.5) / 100, inCar = st.inCar > 0.5,
           carOpen = math.floor(st.carOpen * 100 + 0.5) / 100 }
end

return M
