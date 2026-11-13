-- Rain Puddles & Droplets v1.0
--
-- Universal screen-space wet-road pass, hybrid sky/SSR reflection fallback,
-- volumetric vehicle droplets, a cockpit windshield layer with procedural
-- wipers, aerodynamic droplet advection and procedural tyre spray.
--
-- 1.0 fixes: vehicle data is moved back to where the car is drawn (the physics state Lua reads is one frame ahead
-- of the rendered car, so droplets were cut off at the rear and puddles could show on the car at speed), droplets
-- are kept off the cabin interior with a per-vehicle roof-line profile, the windshield only gets rain where the
-- view really passes through the glass, and running droplets are no longer clipped at high speed.
--
-- Built against the patterns in BeamNG's official PostFX, Compute Shader,
-- Creating an app, Reflections and LevelInfo documentation. The game-side
-- shader headers are those shipped with BeamNG.drive 0.40.x.
--
-- Console:
--   extensions.rainPuddles.status()
--   extensions.rainPuddles.setSetting('rain', 0.8)
--   extensions.rainPuddles.sweep()
--   extensions.rainPuddles.rebuild()

local M = {}

local TAG = 'rainPuddles'
-- 1.0: new folder name on purpose. BeamNG keeps compiled shaders in temp/shaders and does not notice that a mod's
-- shader file changed (measured: edited shaders kept running in their old form across restarts until that cache was
-- cleared). A new path makes every player's game compile the 1.0 shaders instead of reusing cached 0.9 ones.
-- Rename the folder again whenever the shaders change in a release.
local shaderDir = 'shaders/common/postFx/rainPuddles21/'
local maskDir = '/art/rainPuddles/'
local wiperMaskPath = maskDir .. 'wiper_sweep.data.png'
local settingsFile = '/settings/rainPuddles.json'

local MASK_FILES = {
  'puddle_01_lakes.data.png', 'puddle_02_scattered.data.png', 'puddle_03_streaks.data.png',
  'puddle_04_patchy.data.png', 'puddle_05_film.data.png', 'puddle_06_lakes.data.png',
  'puddle_07_scattered.data.png', 'puddle_08_streaks.data.png', 'puddle_09_patchy.data.png',
  'puddle_10_film.data.png', 'puddle_11_lakes.data.png', 'puddle_12_scattered.data.png',
}

local SHADER_P = 'RainPuddles_PuddlesShaderData'
local SHADER_D = 'RainPuddles_DropletsShaderData'
local SHADER_W = 'RainPuddles_WindshieldShaderData'
local SHADER_S = 'RainPuddles_SplashShaderData'
local BLOCK    = 'RainPuddles_StateBlock'
local FX_P     = 'RainPuddles_Puddles'
local FX_D     = 'RainPuddles_Droplets'
local FX_W     = 'RainPuddles_Windshield'
local FX_R     = 'RainPuddles_RearGlass'      -- 1.0: rear / hatch glass (same shader as the windshield)
local FX_S     = 'RainPuddles_Splashes'
local SHADER_L = 'RainPuddles_LensShaderData'
local FX_L     = 'RainPuddles_Lens'
local SHADER_RAIN = 'RainPuddles_RainShaderData'
local FX_RAIN  = 'RainPuddles_Rain'           -- 1.0: the mod's own falling rain (GPU), instead of BeamNG's particle rain
local dropAtlasPath = maskDir .. 'droplet_atlas.data.png'
local PROBES = {}   -- bisect probes removed in 0.4.6 (they found the Vulkan compile bug)

local PRECIP_HEAVY = 'RainPuddles_NativeRain'
local PRECIP_FINE  = 'RainPuddles_NativeSpray'

local defaults = {
  settingsVersion = 20,
  enabled = true,
  wetGround = true,          -- 0.7: global wet ground on/off, independent of the puddles
  puddles = true,
  droplets = true,
  windshield = true,
  splashes = true,
  precipitation = false,     -- BeamNG's own particle rain (1.0: off by default, it costs a lot of CPU; see rainStreaks)
  rainStreaks = true,        -- 1.0: the mod's own falling rain, drawn on the GPU
  rainDropSize = 1.5,        -- 1.0: raindrop size (mm). Drops on the cars and the glass and the falling rain scale with it
  rainStreakIntensity = 0.45,-- 1.0: how visible the falling rain is
  rainStreakLength = 1.0,    -- 1.0: streak length (motion blur of the drops, 1 = a 1/60 s exposure)
  lens = true,
  autoClouds = true,         -- 1.0: overcast sky while it rains (the level's own cover comes back when it stops)

  rain = 0.60,

  -- Puddles (standing water only; the global wet road has its own block below)
  puddleCoverage = 0.36,
  puddleSize = 0.60,
  puddleStrength = 0.32,
  puddleReflection = 0.68,
  puddleRoughness = 0.16,
  puddleRipple = 0.50,
  puddleSoftness = 0.035,
  puddleNormal = 0.08,       -- 0.6: puddle-only (road normal detail moved to roadNormal)
  tileSize = 44,
  surfaceFilter = 0.85,
  maxDistance = 140,
  -- puddle reflections (own trace). 0.6.1: the wet ground has its own copies (road* below)
  skyReflection = 1.00,
  reflectionBlur = 0.45,
  ssrSteps = 48,             -- 1.0: the longest trace by default (catches more of what is under the cars)
  ssrThickness = 2.0,        -- 1.0: the thickest trace by default (fills in what lies behind thin objects)
  puddleFallback = 0,        -- 0.6.2 when a puddle reflection misses: 0 visible sky + scene edges, 1 ambient sky, 2 nothing,
                             -- 3 (1.0) surroundings: the real scene above the camera, from an extra render view

  -- Vehicle body droplets
  dropletDensity = 0.80,
  dropletSize = 0.012,
  dropletRefraction = 1.0,
  dropletSpeed = 1.0,
  dropletSlide = 0.80,
  dropletAero = 1.0,
  dropletInertia = 1.0,
  dropletRunners = 0.60,     -- 0.6: amount of droplets that run off under gravity / airflow
  dropletTrails = 0.50,      -- 0.6: wet trail left behind running droplets

  -- Global wet road (0.6: fully independent of the puddle settings)
  roadWetness = 1.00,        -- how wet the whole road gets at a given rain amount (native film + own film + darkening)
  roadRoughness = 0.40,      -- wet roughness as a fraction of the dry value (1 = stays dry-rough, lower = glossier)
  roadReflection = 0.75,     -- 0.8: ground 'Reflection strength' (native: how much glossier the wet road gets; own: reflectance)
  roadFlood = 0.20,          -- 0.8: how puddle-like the ground gets at full rain (1 = exactly the puddle look; 1.0: was 1 = mirror road)
  roadDarkening = 0.38,      -- wet darkening of the road surface
  roadNormal = 0.80,         -- how much of the road's normal map / asphalt texture shows through the film (own film)
  roadVariation = 0.60,      -- patchiness of the film from the puddle field (0 = uniform)
  -- Global wet ground reflections, own trace (0.6.1: separate from the puddle reflection settings)
  roadSkyReflection = 1.00,  -- sky fallback brightness of the ground film
  roadReflectionBlur = 0.55, -- reflection blur of the ground film
  roadSsrSteps = 48,         -- trace steps on the open road (puddles keep ssrSteps; 1.0: the most by default)
  roadSsrThickness = 2.0,    -- trace thickness on the open road (1.0: the most by default)
  roadFallback = 0,          -- 0.6.2 when a ground-film reflection misses: 0 visible sky + scene edges, 1 ambient sky, 2 nothing
  roadPatchSize = 18,        -- 0.7: size (m) of the ground's own patchiness pattern (independent of the puddle pattern)
  roadMaxDistance = 160,     -- 0.7: how far the wet ground is drawn (puddles keep maxDistance)
  vehMaskHeight = 0.15,      -- 0.7: inside a car's box, anything this far (m) above the road is the car (no puddles on it)
  puddleRoadsOnly = true,    -- 0.8: puddles only inside the lanes of the level's AI road network
  lightStreaks = 0.50,       -- 0.8: vertical streaks of light in wet-road reflections
  stochasticGloss = false,   -- 0.8: GGX-sampled glossy reflections, smoothed by the game's temporal AA/upscaler (1.0: on by
                             -- default when one is on, see below)
  drySim = true,             -- 0.8: the ground gets wet / dries over time instead of following the rain instantly
  wetUpTime = 25,            -- 0.8: seconds for the ground to get wet when rain starts (puddles take ~2.5x longer)
  dryTime = 6,               -- 0.8: minutes for the ground to dry after the rain (puddles last ~1.6x longer)
  followWeather = false,     -- 0.8: take the rain amount from the game's own weather (never touch its rain particles)
  -- Reflection engine (0.5): native PBR + SSR chain
  reflectionMode = 0,        -- 0 Auto, 1 Native PBR + SSR only, 2 Own SSR only
  wetRoadMaterials = true,   -- lower road roughnessFactor while raining so engine reflections/SSR pick the road up
  nativeSsrQuality = 0,      -- 0 keep game setting, 1 Low, 2 Medium, 3 High (PostFXSSRQuality)
  nativeSsrRestore = true,   -- put the player's SSR quality back when the rain stops
  tireMarkGloss = 1.0,
  proceduralMasks = false,
  vehicleMask = true,      -- diagnostic switch: false = no vehicle masking at all (proves/disproves a mask-caused dry box)
  dropletSheen = 0.60,
  dropletShell = 0.55,
  dropletMaxDistance = 40,

  -- Cockpit windshield / wipers
  windshieldDensity = 0.70,
  windshieldSize = 0.005,    -- 1.0: was 0.012 (3 cm drops on the glass)
  wiperAuto = true,          -- 1.0: rain-sensing (intermittent / normal / fast from the rain on the glass)
  windshieldOutside = true,  -- 1.0: the player's windshield rain also shows when looking at the car from outside
  rearGlass = true,          -- 1.0: drops on the rear / hatch glass of the player's car (from its glass mesh)
  rearWiper = true,          -- 1.0: the rear wiper clears the rear glass (cars that have one)
  sideGlass = true,          -- 1.0: drops on the side windows (door / quarter glass) of the player's car
  wiperSpeed = 1.20,
  wiperTrail = 0.55,

  -- Camera lens droplets (0.6)
  lensIntensity = 1.00,      -- opacity / strength of the lens droplets
  lensDensity = 0.55,        -- maximum droplet density (scaled by rain, speed and shelter)
  lensSize = 0.022,          -- droplet radius, fraction of screen height
  lensClearCenter = 0.22,    -- radius of the clear central zone, fraction of screen height
  lensSpeedResponse = 1.00,  -- how strongly vehicle speed sweeps droplets outward
  lensRefraction = 1.00,
  lensInCockpit = false,     -- cockpit views already have the windshield layer

  -- Tyre spray
  splashIntensity = 0.30,   -- 1.0: was 0.80, then 0.50 (the mist was too thick)
  splashSize = 1.0,
  splashSpeedMin = 6.0,
  splashPuddle = 0.35,
  tyreWakes = 1.00,          -- 0.9: waves and churned water behind tyres rolling through puddles
  trafficSpray = true,       -- 0.9: spray and wakes from other vehicles too (up to 8 tyres in total)

  -- 1.0 hydroplaning (node-based, in each car's own Lua: lua/vehicle/extensions/rainPuddlesHydroVeh.lua)
  hydroplaning = 2,          -- 0 off, 1 arcade, 2 simcade, 3 sim
  hydroStrength = 1.0,       -- scales the water's lift and drag
  hydroTread = 7.0,          -- tread depth (mm) of ordinary tyres (slicks, semi-slicks, race and off-road tyres are known)
  hydroTraffic = true,       -- other cars hydroplane too (within 400 m)
  hydroDebug = false,        -- draw every contact-patch node: blue = water under it, red = load the water carries

  -- Native precipitation / dynamic scaling
  precipMaxDrops = 12000,
  precipFollow = true,

  boxLag = 0.0,              -- frames to move the vehicle data back. 1.0 (until settingsVersion 16) only made up for the
                             -- camera position being a frame old; with the camera read while the frame is drawn the
                             -- car boxes match the drawn car at 0 (measured at 25-70 km/h)

  maskA = 1,
  maskB = 4,
  depthMode = 0,
  depthScale = 1.0,
  debugMode = 0,
  debugBrightness = 1.0,
}

local ranges = {
  rain = { 0, 1 },
  rainDropSize = { 0.4, 5 },
  rainStreakIntensity = { 0, 2 },
  rainStreakLength = { 0.2, 3 },
  puddleCoverage = { 0, 0.85 },
  puddleSize = { 0, 1 },
  puddleStrength = { 0, 1 },
  puddleReflection = { 0, 1 },
  puddleRoughness = { 0, 1 },
  puddleRipple = { 0, 2 },
  puddleSoftness = { 0.005, 0.2 },
  puddleNormal = { 0, 2 },
  tileSize = { 6, 120 },
  surfaceFilter = { 0, 1 },
  maxDistance = { 30, 400 },
  skyReflection = { 0, 3 },
  reflectionBlur = { 0, 1 },
  ssrSteps = { 8, 48 },
  ssrThickness = { 0.05, 2.0 },

  dropletDensity = { 0, 1.5 },
  dropletSize = { 0.004, 0.04 },
  dropletRefraction = { -1.5, 1.5 },
  dropletSpeed = { 0.1, 4 },
  dropletSlide = { 0, 1 },
  dropletAero = { 0, 3 },
  dropletInertia = { 0, 2 },
  dropletRunners = { 0, 1 },
  dropletTrails = { 0, 1 },
  roadWetness = { 0, 1 },
  roadRoughness = { 0.05, 1 },
  roadReflection = { 0, 1 },
  roadDarkening = { 0, 1 },
  roadNormal = { 0, 2 },
  roadVariation = { 0, 1 },
  roadSkyReflection = { 0, 3 },
  roadReflectionBlur = { 0, 1 },
  roadSsrSteps = { 8, 48 },
  roadSsrThickness = { 0.05, 2.0 },
  roadFallback = { 0, 3 },
  roadPatchSize = { 4, 120 },
  roadMaxDistance = { 30, 600 },
  vehMaskHeight = { 0.03, 0.8 },
  roadFlood = { 0, 1 },
  lightStreaks = { 0, 1 },
  wetUpTime = { 1, 300 },
  dryTime = { 0.2, 60 },
  puddleFallback = { 0, 3 },
  reflectionMode = { 0, 2 },
  nativeSsrQuality = { 0, 3 },
  tireMarkGloss = { 0, 1 },
  dropletSheen = { 0, 1 },
  dropletShell = { 0.1, 1.0 },
  dropletMaxDistance = { 5, 80 },

  windshieldDensity = { 0, 1.8 },
  windshieldSize = { 0.002, 0.03 },
  boxLag = { 0, 3 },
  wiperSpeed = { 0.1, 3.0 },
  wiperTrail = { 0, 1 },

  lensIntensity = { 0, 2 },
  lensDensity = { 0, 1 },
  lensSize = { 0.008, 0.06 },
  lensClearCenter = { 0, 0.6 },
  lensSpeedResponse = { 0, 3 },
  lensRefraction = { 0, 2 },

  splashIntensity = { 0, 2 },
  splashSize = { 0.25, 4.0 },
  splashSpeedMin = { 0, 40 },
  splashPuddle = { 0, 1 },
  tyreWakes = { 0, 2 },
  hydroplaning = { 0, 3 },
  hydroStrength = { 0, 2 },
  hydroTread = { 0, 12 },

  precipMaxDrops = { 0, 24000 },

  maskA = { 1, 12 },
  maskB = { 1, 12 },
  depthMode = { 0, 2 },
  depthScale = { 0.01, 100 },
  debugMode = { 0, 19 },
  debugBrightness = { 0.05, 50 },
}

local S = {}
local T = 0
-- 1.0: simulation time. The wipers run on it (slow motion / pause slow down or stop the blades, and the clearing with them)
local TS = 0
local sinceCheck = 0
local precipTimer = 0
local saveTimer = 0
local saveDirty = false
local enabledCache = nil
local cam = {
  x = 0, y = 0, z = 0,
  fx = 0, fy = 1, fz = 0,
  rx = 1, ry = 0, rz = 0,
  ux = 0, uy = 0, uz = 1,
  fov = 1.0, aspect = 16 / 9,
  name = nil, cockpit = false, insideVehicle = false, cockpitSince = -1e9,
}
local boxes = {}
local accelState = {}   -- [vehicle id] = last velocity + low-passed acceleration
local frameDtSim = 0
local frameId, camFrame = 0, -1
local VERSION = '1.0.0'
local MAX_VEH_PUDDLES = 12   -- vehicles kept off the puddle / wet-ground pass (must match rp_puddles.h.hlsl)
local MAX_VEH_DROPS = 6      -- vehicles with body droplets (must match rp_droplets.h.hlsl)
local PROFILE_N = 16         -- roof-line samples per vehicle (must match rp_droplets.cs.hlsl)
local playerBox = nil
local playerVeh = nil
local wheels = {}
local windshield = nil
-- Wiper timeline (0.7). The shader rebuilds the blade angle and, for every point of the glass, when a blade last
-- passed over it, from: seconds since the current cycle started, sweep time, period and flags (see windshieldConsts).
local wiper = { cycleStart = -1e9, runStart = -1e9, sweepT = 1.0, period = 1.0, repeating = false, running = false,
                everWiped = false, cycles = 0, active = false, mode = 0, perMin = 0 }
-- Glass rain state: rain clock (how many drops have landed), and (1.0) the drops' physics like the body droplets: force
-- along the glass (fa / fb, m/s^2), running-drop velocity (vx / vy) and travel (ox / oy) in glass units, life clock.
local windFlow = { clock = 0.0, rate = 1.0, speed = 0.0, fa = 0.0, fb = 0.0, vx = 0.0, vy = 0.0, ox = 0.0, oy = 0.0,
                   life = 0.0 }
-- 1.0 rear / hatch glass of the player's car (from its glass mesh), drawn by a second pass of the windshield shader
local rearGlass = nil
local rearFlow = { clock = 0.0, rate = 1.0, speed = 0.0, fa = 0.0, fb = 0.0, vx = 0.0, vy = 0.0, ox = 37.0, oy = 11.0,
                   life = 5.0 }
-- 1.0 side windows (door / quarter glass) of the player's car: one pane per side from its glass meshes, drawn by two
-- more passes of the windshield shader (no wipers: the drops go with the airflow, and slowly under a roof)
local SIDE = { fxL = 'RainPuddles_SideGlassL', fxR = 'RainPuddles_SideGlassR', L = nil, R = nil,
               flowL = { clock = 0.0, rate = 1.0, speed = 0.0, fa = 0.0, fb = 0.0, vx = 0.0, vy = 0.0, ox = 71.0, oy = 23.0,
                         life = 9.0 },
               flowR = { clock = 0.0, rate = 1.0, speed = 0.0, fa = 0.0, fb = 0.0, vx = 0.0, vy = 0.0, ox = 113.0, oy = 41.0,
                         life = 13.0 } }
-- 1.0 rear wiper timeline (same fields as the windshield's)
local rearWiper = { cycleStart = -1e9, runStart = -1e9, sweepT = 1.4, period = 6.0, repeating = false, running = false,
                    everWiped = false, cycles = 0, active = false, ease = 0, perMin = 0 }
-- 1.0 falling rain and shelter state (see 'falling rain' further down). period: a multiple of 1024 cells of both grids.
-- shelter: roof heights over 9 x 9 upward casts around the camera, used by the rain, the ground (dry in tunnels), the
-- cars' drops and the wipers. player: the player's car under a roof (sim time when it went in / came out).
local RAIN = { nearCell = 0.5, farCell = 1.25, maxDist = 22, period = 2560, spacing = 4.0, reach = 60, n = 9 }
local rainSt = { on = false, fx = 0, fy = 0, fz = 0, vx = 0, vy = 0, vz = 0, px = nil, py = nil, pz = nil,
                 wx = 0, wy = 0, windAt = -1e9, lx = 0, ly = 0, lz = 0.1, vt = 6.0,
                 shelter = {}, sox = 0, soy = 0, cache = {}, pruneAt = 0, shStr = nil, shG = '0 0 4 0',
                 dryNear = false, dryNearUntil = -1e9, camCovered = false, vehWet = {}, wetPruneAt = 0,
                 player = { on = false, pend = nil, startTS = nil, endTS = nil, sweeps = 0, wetHold = 0, cov = 0 } }
local precip = { existing = nil, existingName = nil, orig = nil, heavy = nil, fine = nil, count = 0, drops = 0 }
local warned = {}

local function warnOnce(key, msg)
  if not warned[key] then
    warned[key] = true
    log('W', TAG, msg)
  end
end

-- 1.0: with a temporal upscaler / TAA on (XeSS, DLSS, FSR, PSSR, SMAA T2x: the game's own setting) the stochastic
-- glossy reflections are smoothed by it, so they are on by default then
do
  local TEMPORAL = { dlss = true, fsr3 = true, fsr4 = true, xess = true, fsrCustom = true, pssr = true, smaaT2x = true }
  local okT, aa = pcall(function() return settings.getValue('GraphicAntialiasType') end)
  local okE, en = pcall(function() return settings.getValue('GraphicAntialias') end)
  local off = okE and (en == false or en == nil or tonumber(en) == 0)
  defaults.stochasticGloss = (okT and TEMPORAL[aa] and not off) and true or false
end

local function copyTable(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

local function fmt3(a, b, c)
  return string.format('%.6f %.6f %.6f', a, b, c)
end

local function fmt4(a, b, c, d)
  return string.format('%.6f %.6f %.6f %.6f', a, b, c, d)
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function round(v) return math.floor(v + 0.5) end

local function len3(x, y, z)
  return math.sqrt(x * x + y * y + z * z)
end

local function norm3(x, y, z)
  local l = len3(x, y, z)
  if l < 1e-9 then return 0, 0, 1 end
  return x / l, y / l, z / l
end

local function dot3(ax, ay, az, bx, by, bz)
  return ax * bx + ay * by + az * bz
end

-- settings ---------------------------------------------------------------------------------

-- Safe call into the companion extension (rainPuddlesWet): never lets an engine API difference break the mod.
local function wetCall(fn, ...)
  local ext = extensions and extensions.rainPuddlesWet
  if ext and type(ext[fn]) == 'function' then
    local ok, a = pcall(ext[fn], ...)
    if ok then return a end
    log('W', TAG, 'rainPuddlesWet.' .. fn .. ' failed: ' .. tostring(a))
  end
  return nil
end

-- Sends an event to the UI (Vue: useEvents().on(name, handler)).
local function uiTrigger(name, data)
  local gh = rawget(_G, 'guihooks')
  if not (gh and gh.trigger) then
    local ok, mod = pcall(require, 'guihooks')
    if ok then gh = mod end
  end
  if gh and gh.trigger then pcall(gh.trigger, name, data) end
end

local function pushSettings()
  uiTrigger('RainPuddlesSettings', S)
end

local function clampSetting(key, value)
  local r = ranges[key]
  if r then return clamp(value, r[1], r[2]) end
  return value
end

local function loadSettings()
  S = copyTable(defaults)
  local ok, data = pcall(jsonReadFile, settingsFile)
  if ok and type(data) == 'table' then
    for k, v in pairs(data) do
      if defaults[k] ~= nil and type(v) == type(defaults[k]) then
        S[k] = v
      end
    end

    -- v0.3.x -> v0.3.2: puddles were too small by default; apply the new tile size once.
    if (tonumber(data.settingsVersion) or 0) < 4 then
      S.tileSize = defaults.tileSize
      S.dropletInertia = defaults.dropletInertia
    end
    if (tonumber(data.settingsVersion) or 0) < 5 then
      S.roadReflection = defaults.roadReflection
    end
    if (tonumber(data.settingsVersion) or 0) < 7 then
      -- 0.4.0 reworked reflectance (puddles = mirror at strength 1, road film = Fresnel-driven): new defaults.
      S.roadReflection = defaults.roadReflection
      S.puddleReflection = defaults.puddleReflection
    end
    if (tonumber(data.settingsVersion) or 0) < 9 then
      -- 0.6.0 split the global wet road from the puddles. Carry the player's old values over so the look does not
      -- change on update: the old shared normal/darkening sliders now seed BOTH sides, the native smoothness becomes
      -- the new road roughness (roughness = 1 - smoothness).
      local oldSmooth = tonumber(data.wetRoadSmoothness)
      if oldSmooth then S.roadRoughness = clamp(1 - oldSmooth, 0.05, 1) end
      local oldNormal = tonumber(data.puddleNormal)
      if oldNormal then
        S.roadNormal = clamp(oldNormal, 0, 2)
        S.puddleNormal = clamp(oldNormal * 0.15, 0, 2)   -- puddles used to keep 15% of the shared value
      else
        S.puddleNormal = defaults.puddleNormal
      end
      local oldDark = tonumber(data.puddleStrength)
      if oldDark then S.roadDarkening = clamp(oldDark, 0, 1) end
    end
    if (tonumber(data.settingsVersion) or 0) < 10 then
      -- 0.6.1 split the own-trace reflection settings: the ground film gets its own copies of the formerly shared
      -- sky / blur / thickness values; it used to run on ~60% of the puddle step budget.
      if tonumber(data.skyReflection) then S.roadSkyReflection = clamp(tonumber(data.skyReflection), 0, 3) end
      if tonumber(data.reflectionBlur) then S.roadReflectionBlur = clamp(tonumber(data.reflectionBlur), 0, 1) end
      if tonumber(data.ssrThickness) then S.roadSsrThickness = clamp(tonumber(data.ssrThickness), 0.05, 2) end
      if tonumber(data.ssrSteps) then S.roadSsrSteps = clamp(round(tonumber(data.ssrSteps) * 0.6), 8, 48) end
    end
    if (tonumber(data.settingsVersion) or 0) < 11 then
      -- 0.7.0 split the distance: the wet ground keeps the distance the player had for everything.
      if tonumber(data.maxDistance) then S.roadMaxDistance = clamp(tonumber(data.maxDistance), 30, 600) end
    end
    if (tonumber(data.settingsVersion) or 0) < 14 then
      -- 1.0: calmer wet look by default (the old flood = 1 turned the whole road into a mirror in heavy rain). Only
      -- values still at the old defaults are moved; anything the player tuned is kept.
      local old = { rain = 0.65, roadRoughness = 0.40, roadReflection = 0.60, roadFlood = 1.00,
                    puddleCoverage = 0.45, puddleReflection = 0.65, puddleRoughness = 0.18 }
      for k, v in pairs(old) do
        local cur = tonumber(data[k])
        if cur == nil or math.abs(cur - v) < 1e-6 then S[k] = defaults[k] end
      end
    end
    if (tonumber(data.settingsVersion) or 0) < 16 then
      -- 1.0: the camera is now read while the frame is drawn, so the old one-frame vehicle shift is wrong
      local bl = tonumber(data.boxLag)
      if bl == nil or math.abs(bl - 1.0) < 1e-6 then S.boxLag = defaults.boxLag end
    end
    if (tonumber(data.settingsVersion) or 0) < 15 then
      -- 1.0: more reflective wet road that still looks like asphalt (Fresnel-driven film, the asphalt texture shows
      -- through). Values still at the earlier 1.0 defaults are moved; anything the player tuned is kept.
      local old = { roadRoughness = 0.50, roadReflection = 0.50, roadFlood = 0.30, roadNormal = 0.55 }
      for k, v in pairs(old) do
        local cur = tonumber(data[k])
        if cur == nil or math.abs(cur - v) < 1e-6 then S[k] = defaults[k] end
      end
    end
    if (tonumber(data.settingsVersion) or 0) < 18 then
      -- 1.0: fewer puddles and a slightly darker wet road by default (tuned in game); untouched old defaults move
      local old = { puddleCoverage = 0.40, puddleRipple = 0.55, roadDarkening = 0.32, rainStreakIntensity = 0.70 }
      for k, v in pairs(old) do
        local cur = tonumber(data[k])
        if cur == nil or math.abs(cur - v) < 1e-6 then S[k] = defaults[k] end
      end
    end
    if (tonumber(data.settingsVersion) or 0) < 19 then
      -- 1.0 (in-game feedback): softer, sparser falling rain, a lighter tyre spray, the longest / thickest reflection
      -- traces, glassier puddles and stochastic glossy reflections whenever a temporal upscaler is on. Values still at
      -- the earlier defaults move; anything the player tuned is kept.
      local old = { rainStreakIntensity = 0.60, splashIntensity = 0.80, ssrSteps = 28, ssrThickness = 0.35,
                    roadSsrSteps = 16, roadSsrThickness = 0.35, puddleReflection = 0.60, puddleRoughness = 0.20,
                    reflectionBlur = 0.55, roadDarkening = 0.36 }
      for k, v in pairs(old) do
        local cur = tonumber(data[k])
        if cur == nil or math.abs(cur - v) < 1e-6 then S[k] = defaults[k] end
      end
      if data.stochasticGloss ~= true then S.stochasticGloss = defaults.stochasticGloss end
    end
    if (tonumber(data.settingsVersion) or 0) < 20 then
      -- 1.0: an even lighter tyre spray by default (in-game feedback); a strength the player picked is kept
      local cur = tonumber(data.splashIntensity)
      if cur == nil or math.abs(cur - 0.50) < 1e-6 or math.abs(cur - 0.80) < 1e-6 then S.splashIntensity = defaults.splashIntensity end
    end
    if (tonumber(data.settingsVersion) or 0) < 17 then
      -- 1.0: the mod's own GPU rain replaces BeamNG's particle rain, which was on by default and cost a lot of CPU
      S.precipitation = false
    end
    if (tonumber(data.settingsVersion) or 0) < 13 then
      -- 1.0: windshield drops were far too big by default (1.2 cm base radius, up to 3 cm). Only the untouched old
      -- default is replaced; a size the player picked is kept.
      local ws = tonumber(data.windshieldSize)
      if ws == nil or math.abs(ws - 0.012) < 1e-6 then S.windshieldSize = defaults.windshieldSize end
    end
    S.settingsVersion = defaults.settingsVersion

    -- v0.1 / v0.2 migration. There is no version field in those files.
    if tonumber(data.settingsVersion) == nil then
      S.settingsVersion = defaults.settingsVersion
      S.puddleCoverage = clamp(S.puddleCoverage or defaults.puddleCoverage, 0, 0.85)
      S.puddleRoughness = clamp(S.puddleRoughness or defaults.puddleRoughness, 0, 1)
      S.puddleStrength = clamp(S.puddleStrength or defaults.puddleStrength, 0, 1)
      S.puddleReflection = clamp(S.puddleReflection or defaults.puddleReflection, 0, 1)
      S.puddleNormal = defaults.puddleNormal
      S.skyReflection = defaults.skyReflection
      S.reflectionBlur = defaults.reflectionBlur
      S.ssrSteps = defaults.ssrSteps
      S.ssrThickness = defaults.ssrThickness
      S.dropletAero = defaults.dropletAero
      S.windshield = defaults.windshield
      S.splashes = defaults.splashes
      S.windshieldDensity = defaults.windshieldDensity
      S.windshieldSize = defaults.windshieldSize
      S.wiperAuto = defaults.wiperAuto
      S.wiperSpeed = defaults.wiperSpeed
      S.wiperTrail = defaults.wiperTrail
      S.splashIntensity = defaults.splashIntensity
      S.splashSize = defaults.splashSize
      S.splashSpeedMin = defaults.splashSpeedMin
      S.splashPuddle = defaults.splashPuddle
      S.precipMaxDrops = defaults.precipMaxDrops
      S.precipFollow = defaults.precipFollow
    end
  end

  for k, v in pairs(S) do
    if type(v) == 'number' and ranges[k] then
      S[k] = clampSetting(k, v)
    end
  end
end

local function saveSettings()
  local ok, err = pcall(jsonWriteFile, settingsFile, S, true)
  if not ok then
    warnOnce('save', 'could not save settings: ' .. tostring(err))
  else
    saveDirty = false
  end
end

-- wetness simulation (0.8) ---------------------------------------------------------------
-- The rain amount is how hard it rains NOW. The ground gets wet over 'wetUpTime' seconds and dries over 'dryTime'
-- minutes after the rain; puddles fill ~2.5x slower and last ~1.6x longer. Rain particles, ripples, droplets and the
-- windshield follow the rain directly; the wet ground, puddles, native road materials and tyre spray follow the water.
local wetSim = { ground = nil, puddle = nil }

local function updateWetness(dtSim)
  local rain = clamp(S.rain, 0, 1)
  if not S.drySim or wetSim.ground == nil then
    wetSim.ground, wetSim.puddle = rain, rain
    return
  end
  local dt = math.max(tonumber(dtSim) or 0, 0)
  if dt <= 0 then return end
  local function approach(cur, target, upTau, downTau)
    local tau = (target > cur) and upTau or downTau
    return cur + (target - cur) * (1 - math.exp(-dt / math.max(tau, 0.05)))
  end
  local up, down = math.max(S.wetUpTime, 0.5), math.max(S.dryTime, 0.05) * 60
  wetSim.ground = approach(wetSim.ground, rain, up, down)
  wetSim.puddle = approach(wetSim.puddle, rain, up * 2.5, down * 1.6)
end

local function groundWetness() return clamp(wetSim.ground or S.rain, 0, 1) end
local function puddleWater() return clamp(wetSim.puddle or S.rain, 0, 1) end

-- How puddle-like the ground is (0 = wet asphalt .. 1 = exactly the puddle look). Starts at a quarter wetness and
-- rises slowly, so light rain stays wet asphalt and only sustained heavy rain floods the road.
local function floodAmount()
  return clamp(S.roadFlood, 0, 1) * (clamp((groundWetness() - 0.25) / 0.75, 0, 1) ^ 1.5)
end

-- camera / vehicles -------------------------------------------------------------------------

local function callCamera(fn, ...)
  if not core_camera or type(core_camera[fn]) ~= 'function' then return nil end
  local ok, a, b, c = pcall(core_camera[fn], ...)
  if not ok then return nil end
  return a, b, c
end

local function updateCamera()
  local p = callCamera('getPosition')
  if p then cam.x, cam.y, cam.z = p.x, p.y, p.z end

  local f = callCamera('getForward')
  if f then cam.fx, cam.fy, cam.fz = norm3(f.x, f.y, f.z) end
  local r = callCamera('getRight')
  if r then cam.rx, cam.ry, cam.rz = norm3(r.x, r.y, r.z) end
  local u = callCamera('getUp')
  if u then cam.ux, cam.uy, cam.uz = norm3(u.x, u.y, u.z) end
  local fov = callCamera('getFovRad')
  if fov and fov > 0.01 then cam.fov = fov end
  local name = callCamera('getActiveCamName', 0)
  cam.name = name or nil

  local okCanvas, w, h = pcall(function()
    if canvas and canvas.getWindowClientSizeXY then
      return canvas:getWindowClientSizeXY()
    end
    return nil, nil
  end)
  if okCanvas and tonumber(w) and tonumber(h) and h > 0 then
    cam.aspect = w / h
  end
end

local function readBox(veh, boxIndex)
  local oobb = nil
  local ok = pcall(function() oobb = veh:getSpawnWorldOOBB() end)
  if not ok or not oobb then return nil end

  local ok2, c, a0, a1, a2, he = pcall(function()
    return oobb:getCenter(), oobb:getAxis(0), oobb:getAxis(1), oobb:getAxis(2), oobb:getHalfExtents()
  end)
  if not ok2 or not c or not a0 or not a1 or not a2 or not he then return nil end

  local okPos, pos = pcall(function() return veh:getPosition() end)
  if not okPos or not pos then return nil end

  local okVel, vel = pcall(function() return veh:getVelocity() end)
  if not okVel or not vel then vel = { x = 0, y = 0, z = 0 } end

  -- 1.0: the physics state read here is one frame ahead of the car that is drawn this frame (measured in game: at
  -- ~70 km/h the tailgate of a D15 fell ~0.3 m outside its box). Every position taken from it is moved back along the
  -- velocity, so boxes, ground planes, tyres and the windshield sit on the car on screen. Before this, droplets were
  -- cut off at the rear of a moving car and the puddle / wet-ground mask slid off it (puddles on the car).
  local lag = (S.boxLag or 1) * math.max(frameDtSim or 0, 0)
  local lx, ly, lz = vel.x * lag, vel.y * lag, vel.z * lag
  local rcx, rcy, rcz = c.x, c.y, c.z
  c = { x = c.x - lx, y = c.y - ly, z = c.z - lz }
  pos = { x = pos.x - lx, y = pos.y - ly, z = pos.z - lz }

  local wind = { x = 0, y = 0, z = 0 }
  if be and be.getWindAt then
    local okW, wv = pcall(function() return be:getWindAt(vec3(c.x, c.y, c.z + 1.0)) end)
    if okW and wv then wind = wv end
  end

  local id = boxIndex
  local okId, vid = pcall(function() return veh:getID() end)
  if okId and vid then id = vid end

  local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
  local dx, dy, dz = cam.x - c.x, cam.y - c.y, cam.z - c.z
  local d2 = dx * dx + dy * dy + dz * dz
  local inside = math.abs(dx * a0.x + dy * a0.y + dz * a0.z) < he.x
    and math.abs(dx * a1.x + dy * a1.y + dz * a1.z) < he.y
    and math.abs(dx * a2.x + dy * a2.y + dz * a2.z) < he.z

  return {
    id = id, veh = veh,
    cx = c.x, cy = c.y, cz = c.z,
    rcx = rcx, rcy = rcy, rcz = rcz,       -- unshifted centre (same time as the node positions, for the roof line)
    lagX = lx, lagY = ly, lagZ = lz,       -- shift applied to everything read from the physics state
    a0 = { a0.x, a0.y, a0.z }, a1 = { a1.x, a1.y, a1.z }, a2 = { a2.x, a2.y, a2.z },
    h = { he.x, he.y, he.z },
    px = pos.x, py = pos.y, pz = pos.z,
    vx = vel.x, vy = vel.y, vz = vel.z, speed = speed,
    wx = wind.x, wy = wind.y, wz = wind.z,
    d2 = d2, inside = inside,
    seed = ((math.abs(id) % 97) / 97),
    wake = 0.0,
  }
end

-- In-car cameras. 0.40 calls the driver seat camera "occupant.FL" (0.6 only knew "driver", so the windshield never
-- switched on). Hood / bumper cameras sit in front of the glass: they get the lens drops instead.
local COCKPIT_KEYS = { 'occupant', 'driver', 'passenger', 'interior', 'cockpit', 'dashboard', 'inside', 'firstperson', 'fpv', 'onboard' }
local NOT_COCKPIT_KEYS = { 'hood', 'bonnet', 'bumper', 'orbit', 'chase', 'external', 'free', 'wheel' }
local function isCockpitName(name)
  if type(name) ~= 'string' then return false end
  local n = name:lower()
  for _, k in ipairs(NOT_COCKPIT_KEYS) do
    if n:find(k, 1, true) then return false end
  end
  for _, k in ipairs(COCKPIT_KEYS) do
    if n:find(k, 1, true) then return true end
  end
  return false
end

local function computeWake(box, list)
  -- A cheap visual approximation of the wake behind a car. The engine applies
  -- the real slipstream in core_interAero; this only drives droplet advection,
  -- so it never feeds back into physics.
  local fx, fy, fz = box.a1[1], box.a1[2], box.a1[3]
  local rx, ry, rz = box.a0[1], box.a0[2], box.a0[3]
  local wake = 0.0
  for i = 1, #list do
    local other = list[i]
    if other ~= box then
      local dx, dy, dz = other.cx - box.cx, other.cy - box.cy, other.cz - box.cz
      local along = dot3(dx, dy, dz, fx, fy, fz)
      if along > 1.5 and along < 28 then
        local lat = math.abs(dot3(dx, dy, dz, rx, ry, rz))
        local width = math.max(box.h[1], other.h[1]) + 3.2
        if lat < width then
          local fLong = clamp(1.0 - (along - 1.5) / 26.5, 0, 1)
          local fLat = clamp(1.0 - lat / width, 0, 1)
          wake = math.max(wake, 0.55 * fLong * fLat * clamp(other.speed / 25.0, 0, 1))
        end
      end
    end
  end
  box.wake = wake
  return wake
end

-- Ground plane under a vehicle box. The shaders use it to tell road from bodywork (height above the plane).
--
-- Why this exists (dry-box bug): the old code used ONE ground height from a single centre ray cast, refreshed only
-- every 20 frames and never validated. At speed that value is metres stale, it ignores slope across the 4-5 m box,
-- and a ray that passes through a mesh road / hits a bridge deck returns the wrong surface. Any error above ~0.22 m
-- made the road inside the (correctly moving) box count as bodywork, so it stayed dry: a moving dry rectangle.
--
-- Now: the plane comes analytically from the LOWER FACE of the oriented box (same world space as the box, every
-- frame, tilts with the car). The ray cast can only RAISE it (ground = max(box plane, ray)), because the two failure
-- modes are asymmetric: a box whose bottom lies BELOW the road (padded/odd OOBB) or a ray that falls through a mesh
-- road onto terrain both give a ground that is too LOW, which turns road into 'bodywork' (dry rectangle). A ground
-- that is too high only under-masks the lowest bodywork. v0.4.0 clamped the ray to +-0.30 m, which threw away the
-- one correct sample in exactly the 'box bottom below road' case; fixed in 0.4.1.
local GROUND_RAY_MAX_RAISE = 1.2   -- m above the box plane a ray hit may lift the ground (larger = rejected)
local GROUND_RAY_INTERVAL = 0.12   -- s (real time) between casts per vehicle
local GROUND_RAY_MOVED = 0.25      -- m moved since the last cast that forces a new one
local GROUND_RAY_TTL = 0.60        -- s: a cast older than this is dropped, never reused
local groundCastBudget = 0

local function boxGroundPlane(b)
  local ax, hu = b.a2, b.h[3]
  local best = math.abs(b.a2[3])
  if math.abs(b.a0[3]) > best then ax, hu, best = b.a0, b.h[1], math.abs(b.a0[3]) end
  if math.abs(b.a1[3]) > best then ax, hu, best = b.a1, b.h[2], math.abs(b.a1[3]) end
  local ux, uy, uz = ax[1], ax[2], ax[3]
  if uz < 0 then ux, uy, uz = -ux, -uy, -uz end
  local lowZ = b.cz - (math.abs(b.a0[3]) * b.h[1] + math.abs(b.a1[3]) * b.h[2] + math.abs(b.a2[3]) * b.h[3])
  if uz < 0.5 then
    -- vehicle on its side / roof: a slope-form plane is ill-conditioned, use a level plane at the lowest point
    return lowZ, 0, 0, lowZ
  end
  local px, py, pz = b.cx - ux * hu, b.cy - uy * hu, b.cz - uz * hu   -- centre of the lower face
  local sx, sy = -ux / uz, -uy / uz                                   -- dz/dx, dz/dy
  local g0 = pz + sx * (b.cx - px) + sy * (b.cy - py)                 -- plane height at the box centre (x, y)
  return g0, sx, sy, lowZ
end

-- Returns (rayGround - g0): positive = the road is above the box plane. Nil = no usable cast.
local function rayGroundCorrection(b, g0)
  if type(castRayStatic) ~= 'function' then return nil end
  local sz = b.cz + 0.8
  local ok, dist = pcall(castRayStatic, vec3(b.cx, b.cy, sz), vec3(0, 0, -1), 6.0)
  if not ok or type(dist) ~= 'number' or dist <= 0.01 or dist >= 5.99 then return nil end
  local d = (sz - dist) - g0
  if d ~= d or d > GROUND_RAY_MAX_RAISE then return nil end
  return d
end

-- Finite-difference acceleration of each tracked vehicle, low-passed (tau 0.15 s) so physics
-- jitter does not shake the droplets. Frozen while the simulation is paused; reset on teleports.
local function updateAccel(list, dt)
  local seen = {}
  groundCastBudget = 4   -- nearest vehicles first (list is sorted by distance)
  for i = 1, #list do
    local b = list[i]
    local st = accelState[b.id]
    if not st then
      st = { vx = b.vx, vy = b.vy, vz = b.vz, ax = 0, ay = 0, az = 0 }
      accelState[b.id] = st
    end
    if dt > 1e-4 then
      local rx, ry, rz = (b.vx - st.vx) / dt, (b.vy - st.vy) / dt, (b.vz - st.vz) / dt
      if rx * rx + ry * ry + rz * rz > 80 * 80 then rx, ry, rz = 0, 0, 0 end
      local k = 1 - math.exp(-dt / 0.15)
      st.ax = st.ax + (rx - st.ax) * k
      st.ay = st.ay + (ry - st.ay) * k
      st.az = st.az + (rz - st.az) * k
      st.vx, st.vy, st.vz = b.vx, b.vy, b.vz
    end
    b.ax, b.ay, b.az = st.ax, st.ay, st.az
    -- Droplet flow clock (0.6). Droplet life cycles and run-off distances are measured in this clock instead of
    -- seconds, so a change of speed changes how FAST droplets move/respawn, never WHERE they are (no jumps).
    -- It runs at 1/s parked and faster with the relative airflow; it is frozen while the simulation is paused.
    local rx, ry, rz = b.wx - b.vx, b.wy - b.vy, b.wz - b.vz
    local air = math.sqrt(rx * rx + ry * ry + rz * rz) * (1.0 - 0.55 * (b.wake or 0))
    local airRate = math.min((air / 16.0) ^ 2, 6.0)
    st.flow = ((st.flow or (b.seed * 97.0)) + math.max(dt, 0) * (S.dropletSpeed or 1) * (1.0 + airRate)) % 16384.0
    b.flow, b.air = st.flow, air
    -- 0.7 droplet streams: how far running drops have travelled on the body (m). Backward with the airflow above
    -- ~25 km/h (same rate formula as the shader), surging forward under braking; down the panels with gravity.
    local a1x, a1y, a1z = b.a1[1], b.a1[2], b.a1[3]                       -- OBB axis 1 points to the rear
    local airBack = (rx * a1x + ry * a1y + rz * a1z) * (1.0 - 0.65 * (b.wake or 0))
    local vAir = math.max(airBack - 7.0, 0) * 0.05 * (S.dropletAero or 1)
    local accBack = (st.ax or 0) * a1x + (st.ay or 0) * a1y + (st.az or 0) * a1z
    vAir = vAir - accBack * 0.012 * (S.dropletInertia or 1)
    st.sAir = ((st.sAir or 0) + vAir * math.max(dt, 0)) % 4096.0
    st.sGrav = ((st.sGrav or 0) + 0.03 * (S.dropletSlide or 0.8) * math.max(dt, 0)) % 4096.0
    b.sAir, b.sGrav = st.sAir, st.sGrav
    local g0, sx, sy = boxGroundPlane(b)
    local mx, my = b.cx - (st.rx or 1e9), b.cy - (st.ry or 1e9)
    if groundCastBudget > 0 and (T - (st.rayAt or -1e9) > GROUND_RAY_INTERVAL or mx * mx + my * my > GROUND_RAY_MOVED * GROUND_RAY_MOVED) then
      groundCastBudget = groundCastBudget - 1
      st.rayAt, st.rx, st.ry = T, b.cx, b.cy
      local d = rayGroundCorrection(b, g0)
      st.rayOff = d
    end
    if st.rayOff and T - (st.rayAt or -1e9) > GROUND_RAY_TTL then st.rayOff = nil end
    b.g0, b.rayOff = g0, st.rayOff
    b.gz = g0 + math.max(0, st.rayOff or 0)   -- the ray may only raise the ground
    b.gsx, b.gsy = sx, sy
    seen[b.id] = true
  end
  for id in pairs(accelState) do
    if not seen[id] then accelState[id] = nil end
  end
end

-- Roof line (1.0) ----------------------------------------------------------------------------------------------------
-- The highest node of the car in PROFILE_N slices along its length, as a height in the box frame. The droplet shader
-- only gives up-facing surfaces beads where nothing of the car lies above them (roof, hood, boot lid, bed rails):
-- headrests, dashboards, parcel shelves and boot floors seen through the glass sit below the roof line and stay dry.
-- (Car glass is drawn after the G-buffer, so the shader sees the interior behind it, never the glass itself.)
local profiles = {}   -- [vid] = { at = time, v = { PROFILE_N heights } }

local function computeProfile(b)
  local veh = b.veh
  local okN, n = pcall(function() return veh:getNodeCount() end)
  n = okN and tonumber(n) or 0
  if n <= 0 then return nil end
  local hl = math.max(b.h[2], 0.1)
  local a1, a2 = b.a1, b.a2
  local v = {}
  for k = 1, PROFILE_N do v[k] = -1e9 end
  local ok = pcall(function()
    for i = 0, n - 1 do
      local x, y, z = veh:getNodeAbsPositionXYZ(i)
      local dx, dy, dz = x - b.rcx, y - b.rcy, z - b.rcz          -- unshifted centre: same time as the nodes
      local ly = dx * a1[1] + dy * a1[2] + dz * a1[3]
      local lz = dx * a2[1] + dy * a2[2] + dz * a2[3]
      local s = math.floor((ly / hl * 0.5 + 0.5) * PROFILE_N) + 1
      if s >= 1 and s <= PROFILE_N and lz > v[s] then v[s] = lz end
    end
  end)
  if not ok then return nil end
  local any = false
  for k = 1, PROFILE_N do if v[k] > -1e8 then any = true break end end
  if not any then return nil end
  for k = 2, PROFILE_N do if v[k] < -1e8 and v[k - 1] > -1e8 then v[k] = v[k - 1] end end   -- empty end slices
  for k = PROFILE_N - 1, 1, -1 do if v[k] < -1e8 and v[k + 1] > -1e8 then v[k] = v[k + 1] end end
  -- Roof panels have nodes only at their edges: a slice between two higher slices (within two slices on each side)
  -- is a gap in the node cloud, not a dip in the car. Close it (measured on a D15: the mid-roof slice read 0.65 m
  -- instead of 0.86 m, which let the headrests through).
  local closed = {}
  for k = 1, PROFILE_N do
    local l = math.max(v[math.max(k - 1, 1)], v[math.max(k - 2, 1)])
    local r = math.max(v[math.min(k + 1, PROFILE_N)], v[math.min(k + 2, PROFILE_N)])
    closed[k] = math.max(v[k], math.min(l, r))
  end
  return closed
end

-- one vehicle per frame, each refreshed every 3 s (a crash changes the shape)
local function updateProfiles()
  local done = false
  for i = 1, math.min(#boxes, MAX_VEH_DROPS) do
    local b = boxes[i]
    local p = profiles[b.id]
    if not p or (not done and T - p.at > 3.0) then
      if done then break end
      done = true
      profiles[b.id] = { at = T, v = computeProfile(b) }
    end
  end
end

local function collectBoxes()
  local count = 0
  local okCount, c = pcall(function() return be:getObjectCount() end)
  if okCount and c then count = c end
  local list = {}
  for i = 0, count - 1 do
    local ok, veh = pcall(function() return be:getObject(i) end)
    if ok and veh then
      local box = readBox(veh, i)
      if box then list[#list + 1] = box end
    end
  end
  table.sort(list, function(a, b) return a.d2 < b.d2 end)
  -- 1.0: 12 vehicles (was 6) are kept off the puddles, so parked cars and traffic beyond the nearest six no longer get
  -- puddles on their roofs and hoods; the droplet pass uses the nearest MAX_VEH_DROPS of them.
  while #list > MAX_VEH_PUDDLES do list[#list] = nil end

  for i = 1, #list do computeWake(list[i], list) end
  updateAccel(list, frameDtSim)
  boxes = list

  playerVeh = nil
  local okP, pv = pcall(getPlayerVehicle, 0)
  if okP and pv then
    playerVeh = pv
  else
    local okP2, pv2 = pcall(function() return be:getPlayerVehicle(0) end)
    if okP2 then playerVeh = pv2 end
  end

  playerBox = nil
  if playerVeh then
    local okId, pid = pcall(function() return playerVeh:getID() end)
    if okId and pid then
      for i = 1, #boxes do
        if boxes[i].id == pid then playerBox = boxes[i]; break end
      end
    end
  end

  cam.insideVehicle = playerBox ~= nil and playerBox.inside or false
  -- 1.0: the game's own test first (core_camera.isCameraInside: the camera sits at one of the car's interior camera
  -- nodes), the camera-name heuristic as a fallback. Either one is enough, so very high speeds (where the game's
  -- 0.6 m node test can miss for a frame) do not make the windshield flicker.
  local official = false
  if playerBox and core_camera and type(core_camera.isCameraInside) == 'function' then
    local okIn, v = pcall(core_camera.isCameraInside, 0, vec3(cam.x, cam.y, cam.z))
    official = okIn and (v == 1 or v == true) or false
  end
  local byName = cam.insideVehicle and (isCockpitName(cam.name) or cam.name == nil)
  local wasCockpit = cam.cockpit
  cam.cockpit = (playerBox ~= nil) and (official or byName) or false
  if cam.cockpit and not wasCockpit then cam.cockpitSince = T end
  if S.droplets then updateProfiles() end
end

-- screen projection -------------------------------------------------------------------------

local function projectWorld(x, y, z)
  local dx, dy, dz = x - cam.x, y - cam.y, z - cam.z
  local zv = dot3(dx, dy, dz, cam.fx, cam.fy, cam.fz)
  if zv <= 0.08 then return nil end
  local xv = dot3(dx, dy, dz, cam.rx, cam.ry, cam.rz)
  local yv = dot3(dx, dy, dz, cam.ux, cam.uy, cam.uz)
  local tanHalf = math.tan(cam.fov * 0.5)
  if tanHalf < 1e-4 then return nil end
  local nx = xv / (zv * tanHalf * cam.aspect)
  local ny = yv / (zv * tanHalf)
  return (nx + 1) * 0.5, (1 - ny) * 0.5, zv
end

local WIND = { rake = 0.84, fwdK = 0.55, upK = 0.15, minD = 0.35, maxD = 1.6 }  -- rake: rad from vertical (1.0: ~48 deg, was 30)

local function vecCall(veh, fn)
  local ok, v = pcall(function() return veh[fn](veh) end)
  if ok and v then return v.x, v.y, v.z end
end

-- Real windshield per vehicle (0.7.1), found by lua/vehicle/extensions/rainPuddlesProbe.lua from the car's own
-- collision triangles (roof -> 5 cm down -> forward probe + a fan of rays from the eye). Stored in vehicle-local
-- coordinates, so it is found once per car and follows the car afterwards.
local windProbe = {}      -- [vehicle id] = result table from the vehicle ({ ok = true, c, n, r, u, hw, hh, ... })
local probeAsk = {}       -- [vehicle id] = { at = time of the last request, tries = n }

-- 1.0: a probe is good once it found this many points on the glass; weaker results are kept but probed again.
local PROBE_GOOD_HITS = 24

local function requestWindshieldProbe(b, frameOnly)
  local vid = b.id
  local have = windProbe[vid]
  if have and (have.final or have.frame or (have.ok and (have.hits or 0) >= PROBE_GOOD_HITS)) then return end
  -- 1.0: from outside the car only the jbeam frame can be read (the ray probe needs the driver's eye); one attempt per
  -- car is enough there, the cockpit probe tries the rest
  if frameOnly and have then return end
  local st = probeAsk[vid] or { at = -1e9, tries = 0 }
  probeAsk[vid] = st
  if T - st.at < 2.5 then return end
  if st.tries >= 4 then
    if have then have.final = true
    else windProbe[vid] = { ok = false, final = true, note = 'no answer from the vehicle Lua probe' } end
    return
  end
  st.at, st.tries = T, st.tries + 1
  local cmd = string.format(
    "if not rainPuddlesProbe then extensions.load('rainPuddlesProbe') end if rainPuddlesProbe then rainPuddlesProbe.run(%.4f,%.4f,%.4f,%d,%d) end",
    cam.x - b.px, cam.y - b.py, cam.z - b.pz, vid, frameOnly and 1 or 0)
  local ok = pcall(function() b.veh:queueLuaCommand(cmd) end)
  if not ok then windProbe[vid] = { ok = false, final = true, note = 'queueLuaCommand not available' } end
end

-- Real wipers (1.0) --------------------------------------------------------------------------------------------------
-- No BeamNG car animates its wipers: they are static meshes, and no car has wiper motion data (checked in every
-- official vehicle: no wiper props, no wiper Lua). Each car's own wiper MESH is real, though: this reads its vertices
-- (veh:getFlexmesh(fid), as the game's part camera does), keeps the ones lying on this windshield (rear and headlight
-- wipers fall away), splits them into blades, and measures each blade's pivot, length and parked angle on the glass.
-- The windshield layer then sweeps exactly those blades; the parked 3D mesh is hidden in the cockpit while they run.
local wiperGeo = {}    -- [vid] = { blades = { { px, py, park, range, r0, r1 } }, meshes = { names } } (glass pc units)
local wiperHidden = {} -- [vid] = { names } currently hidden by the mod

local function vehicleData(vid)
  local vd = nil
  pcall(function() vd = core_vehicle_manager.getVehicleData(vid) end)
  return vd and vd.vdata or nil
end

-- Maps jbeam-space positions (flexmesh rest pose: getInitVertexPos) to the car's current pose, relative to the vehicle
-- position in world axes, through the car's reference nodes (ref / back / left). Measured on a D15: within 3.4 cm of
-- the live node positions (suspension sag). getDebugVertexPos only works while the game's flexbody debug is on.
local function jbeamMapper(b, vdata)
  local rn = vdata.refNodes and vdata.refNodes[0]
  local nodes = vdata.nodes
  if not (rn and nodes and rn.ref and rn.back and rn.left) then return nil end
  local function jpos(cid) local n = nodes[cid] return n and n.pos and vec3(n.pos) or nil end
  local function wpos(cid) local x, y, z = b.veh:getNodeAbsPositionXYZ(cid) return vec3(x, y, z) end
  local function frame(get)
    local r, bk, lf = get(rn.ref), get(rn.back), get(rn.left)
    if not (r and bk and lf) then return nil end
    local f1 = (bk - r):normalized()
    local l = lf - r
    local f2 = (l - f1 * l:dot(f1)):normalized()
    return r, f1, f2, f1:cross(f2)
  end
  local okJ, rj, a1, a2, a3 = pcall(frame, jpos)
  local okW, rw, c1, c2, c3 = pcall(frame, wpos)
  if not (okJ and okW and rj and rw) then return nil end
  local okP, vp = pcall(function() return vec3(b.veh:getPosition()) end)
  if not okP then return nil end
  local base = rw - vp
  return function(p)
    local d = vec3(p) - rj
    local w = base + c1 * d:dot(a1) + c2 * d:dot(a2) + c3 * d:dot(a3)
    return w.x, w.y, w.z
  end
end

-- 1.0 glass from the car's own glass MESH ------------------------------------------------------------------------------
-- The pane's vertices (rest pose, through jbeamMapper) give its exact outline and curve. Preferred over the jbeam frame,
-- whose nodes can reach past the glass: on the ETK 800 the frame ran under the roof and put windshield rain on the
-- sunroof. kind = 'front' (windshield) or 'rear' (rear window / tailgate / hatch glass). The result uses the probe's
-- vehicle-local convention (x right, y forward, z up; positions relative to the vehicle position), so buildWindshield
-- and the wiper scan take it exactly like a probe result.
local GLASS_NAMES = {
  front = { 'windshield', 'windscreen' },
  rear  = { 'tailgateglass', 'rearglass', 'rear_glass', 'rearwindow', 'rear_window', 'backglass', 'back_glass',
            'hatchglass', 'hatch_glass', 'trunkglass', 'liftgateglass', 'rearwindshield', 'rear_windshield' },
}
local GLASS_SKIP = { '_int', 'dmg', 'damage', 'broken', 'wiper', 'frame', 'seal', 'trim', 'decal', 'sticker', 'tint',
                     'heater', 'defrost', 'washer', 'light', 'lamp' }
-- 1.0 side windows: door, quarter and vent glass of both sides (each mesh goes to the side its vertices are on)
GLASS_NAMES.side = { 'doorglass', 'door_glass', 'sideglass', 'side_glass', 'quarterglass', 'quarter_glass', 'sidewindow',
                     'side_window', 'doorwindow', 'door_window', 'ventglass', 'vent_glass', 'window_l', 'window_r' }
GLASS_NAMES.sideSkip = { 'windownet', 'frit', 'sunroof', 'firewall', 'bolt', 'mount', 'mirror', 'signal', 'beacon' }
local glassMesh = {}      -- [vid] = { front = result | false, rear = result | false }

local function glassMeshName(name, kind)
  local l = name:lower()
  for _, s in ipairs(GLASS_SKIP) do if l:find(s, 1, true) then return false end end
  if kind == 'side' then
    for _, s in ipairs(GLASS_NAMES.sideSkip) do if l:find(s, 1, true) then return false end end
    if glassMeshName(name, 'front') or glassMeshName(name, 'rear') then return false end
  end
  for _, s in ipairs(GLASS_NAMES[kind]) do if l:find(s, 1, true) then return true end end
  return false
end

-- smallest-eigenvalue eigenvector of a symmetric 3x3 matrix (Jacobi rotations)
local function smallestEigen(m)
  local a = { { m[1][1], m[1][2], m[1][3] }, { m[2][1], m[2][2], m[2][3] }, { m[3][1], m[3][2], m[3][3] } }
  local v = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
  for _ = 1, 24 do
    for p = 1, 2 do
      for q = p + 1, 3 do
        if math.abs(a[p][q]) > 1e-12 then
          local th = (a[q][q] - a[p][p]) / (2 * a[p][q])
          local t = (th >= 0 and 1 or -1) / (math.abs(th) + math.sqrt(th * th + 1))
          local c = 1 / math.sqrt(t * t + 1)
          local s = t * c
          for k = 1, 3 do
            local akp, akq = a[k][p], a[k][q]
            a[k][p], a[k][q] = c * akp - s * akq, s * akp + c * akq
          end
          for k = 1, 3 do
            local apk, aqk = a[p][k], a[q][k]
            a[p][k], a[q][k] = c * apk - s * aqk, s * apk + c * aqk
          end
          for k = 1, 3 do
            local vkp, vkq = v[k][p], v[k][q]
            v[k][p], v[k][q] = c * vkp - s * vkq, s * vkp + c * vkq
          end
        end
      end
    end
  end
  local best = 1
  for i = 2, 3 do if a[i][i] < a[best][best] then best = i end end
  return { v[1][best], v[2][best], v[3][best] }
end

-- convex hull (monotone chain) of 2D points {x, y}, counter-clockwise
local function hull2(pts)
  table.sort(pts, function(p, q) return p[1] < q[1] or (p[1] == q[1] and p[2] < q[2]) end)
  local function cross(o, a, b) return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1]) end
  local lower, upper = {}, {}
  for _, p in ipairs(pts) do
    while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], p) <= 0 do lower[#lower] = nil end
    lower[#lower + 1] = p
  end
  for i = #pts, 1, -1 do
    local p = pts[i]
    while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], p) <= 0 do upper[#upper] = nil end
    upper[#upper + 1] = p
  end
  lower[#lower] = nil
  upper[#upper] = nil
  for _, p in ipairs(upper) do lower[#lower + 1] = p end
  return lower
end

-- fx/ux/rx: the car's forward / up / right (world, unit) at the time of the call. 1.0: kind 'sideL' / 'sideR' = the
-- side windows of that side (all its door / quarter glass as one pane: the pillars between them are bodywork, which the
-- shader's depth test leaves dry)
local function glassFromMesh(b, kind, F, U, R)
  local vdata = vehicleData(b.id)
  local list = vdata and vdata.flexbodies
  if type(list) ~= 'table' then return nil end
  local toCar = jbeamMapper(b, vdata)
  if not toCar then return nil end
  local side = (kind == 'sideL') and -1 or ((kind == 'sideR') and 1 or nil)
  local P, names = {}, {}
  for _, fb in pairs(list) do
    local name = type(fb) == 'table' and fb.mesh
    if type(name) == 'string' and glassMeshName(name, side and 'side' or kind) then
      local obj, n = nil, 0
      pcall(function() obj = fb.fid and b.veh:getFlexmesh(fb.fid) end)
      if obj then pcall(function() n = obj:getVertexCount() end) end
      if n >= 4 and n <= 40000 then
        local step = math.max(1, math.floor(n / 3000))
        local Q = {}
        pcall(function()
          for i = 0, n - 1, step do
            local x, y, z = toCar(obj:getInitVertexPos(i))
            -- vehicle-local (x right, y forward, z up)
            Q[#Q + 1] = { x * R[1] + y * R[2] + z * R[3], x * F[1] + y * F[2] + z * F[3], x * U[1] + y * U[2] + z * U[3] }
          end
        end)
        local keep = #Q > 0
        if keep and side then
          local sx = 0
          for _, q in ipairs(Q) do sx = sx + q[1] end
          keep = sx / #Q * side > 0.25                     -- this mesh lies on that side of the car
        end
        if keep then
          for _, q in ipairs(Q) do P[#P + 1] = q end
          names[#names + 1] = name
        end
      end
    end
  end
  if #P < 8 then return nil end
  -- plane: centroid + the direction of least spread
  local cx, cy, cz = 0, 0, 0
  for _, p in ipairs(P) do cx, cy, cz = cx + p[1], cy + p[2], cz + p[3] end
  cx, cy, cz = cx / #P, cy / #P, cz / #P
  -- the pane must sit on the car (positions are relative to the vehicle). Read while the car is still spawning (or
  -- being reloaded, e.g. by the Animated Wipers mod) the positions can come out in absolute world units: retry later.
  if math.abs(cx) > 6 or math.abs(cy) > 8 or math.abs(cz) > 5 then return nil, 'retry' end
  local m = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
  for _, p in ipairs(P) do
    local d = { p[1] - cx, p[2] - cy, p[3] - cz }
    for i = 1, 3 do for j = 1, 3 do m[i][j] = m[i][j] + d[i] * d[j] end end
  end
  local n = smallestEigen(m)
  local nl = math.sqrt(n[1] * n[1] + n[2] * n[2] + n[3] * n[3])
  if nl < 1e-6 then return nil end
  n = { n[1] / nl, n[2] / nl, n[3] / nl }
  -- outward: the windshield faces forward / up, the rear glass backward / up, a side window to its side
  if side then
    if n[1] * side < 0 then n = { -n[1], -n[2], -n[3] } end
  else
    local want = (kind == 'front') and 1 or -1
    if n[2] * want + n[3] * 0.25 < 0 then n = { -n[1], -n[2], -n[3] } end
  end
  -- glass axes: r = the car's right in the plane (1.0 side windows: its forward), u = up along the glass
  local rr = side and { -n[2] * n[1], 1 - n[2] * n[2], -n[2] * n[3] } or { 1 - n[1] * n[1], -n[1] * n[2], -n[1] * n[3] }
  local rl = math.sqrt(rr[1] * rr[1] + rr[2] * rr[2] + rr[3] * rr[3])
  if rl < 1e-3 then return nil end
  rr = { rr[1] / rl, rr[2] / rl, rr[3] / rl }
  -- r stays the car's right (the wipers and right-hand-drive mirroring rely on it); u points up the glass
  local u = { rr[2] * n[3] - rr[3] * n[2], rr[3] * n[1] - rr[1] * n[3], rr[1] * n[2] - rr[2] * n[1] }
  if u[3] < 0 then u = { -u[1], -u[2], -u[3] } end
  local q = {}
  local amin, amax, vmin, vmax = math.huge, -math.huge, math.huge, -math.huge
  for _, p in ipairs(P) do
    local dx, dy, dz = p[1] - cx, p[2] - cy, p[3] - cz
    local a = dx * rr[1] + dy * rr[2] + dz * rr[3]
    local v = dx * u[1] + dy * u[2] + dz * u[3]
    local d = dx * n[1] + dy * n[2] + dz * n[3]
    q[#q + 1] = { a, v, d }
    amin, amax, vmin, vmax = math.min(amin, a), math.max(amax, a), math.min(vmin, v), math.max(vmax, v)
  end
  local hw, hh = (amax - amin) / 2, (vmax - vmin) / 2
  if hw < 0.2 or hh < 0.12 or hw > 1.6 or hh > 1.2 then return nil end
  -- recentre on the middle of the pane
  local ma, mv = (amax + amin) / 2, (vmax + vmin) / 2
  cx, cy, cz = cx + rr[1] * ma + u[1] * mv, cy + rr[2] * ma + u[2] * mv, cz + rr[3] * ma + u[3] * mv
  for _, t in ipairs(q) do t[1], t[2] = t[1] - ma, t[2] - mv end
  -- bulge: d = k0 + k1 b + (k2 + k3 b) a^2 (least squares, the same model as the jbeam frame)
  local A = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }
  local B = { 0, 0, 0, 0 }
  for _, t in ipairs(q) do
    local a2 = t[1] * t[1]
    local row = { 1, t[2], a2, t[2] * a2 }
    for i = 1, 4 do
      B[i] = B[i] + row[i] * t[3]
      for j = 1, 4 do A[i][j] = A[i][j] + row[i] * row[j] end
    end
  end
  local curv = nil
  do  -- Gauss-Jordan
    local M = {}
    for i = 1, 4 do M[i] = { A[i][1], A[i][2], A[i][3], A[i][4], B[i] } end
    local ok = true
    for c = 1, 4 do
      local piv = c
      for r = c + 1, 4 do if math.abs(M[r][c]) > math.abs(M[piv][c]) then piv = r end end
      if math.abs(M[piv][c]) < 1e-9 then ok = false break end
      M[c], M[piv] = M[piv], M[c]
      for r = 1, 4 do
        if r ~= c then
          local f = M[r][c] / M[c][c]
          for k = c, 5 do M[r][k] = M[r][k] - f * M[c][k] end
        end
      end
    end
    if ok then
      curv = { M[1][5] / M[1][1], M[2][5] / M[2][2], M[3][5] / M[3][3], M[4][5] / M[4][4] }
      for i = 1, 4 do if curv[i] ~= curv[i] or math.abs(curv[i]) > 2 then curv = nil break end end
    end
  end
  -- outline: convex hull in glass uv, reduced to at most 12 corners (drop the corner that changes the area least)
  local h = {}
  for _, t in ipairs(q) do h[#h + 1] = { t[1] / hw, t[2] / hh } end
  h = hull2(h)
  while #h > 12 do
    local bestI, bestA = 1, math.huge
    for i = 1, #h do
      local p0, p1, p2 = h[(i - 2) % #h + 1], h[i], h[i % #h + 1]
      local area = math.abs((p1[1] - p0[1]) * (p2[2] - p0[2]) - (p1[2] - p0[2]) * (p2[1] - p0[1]))
      if area < bestA then bestI, bestA = i, area end
    end
    table.remove(h, bestI)
  end
  if #h < 3 then return nil end
  local poly = {}
  for _, p in ipairs(h) do poly[#poly + 1], poly[#poly + 2] = p[1], p[2] end
  return { ok = true, frame = true, mesh = table.concat(names, '+'), c = { cx, cy, cz }, n = n, r = rr, u = u,
           hw = hw, hh = hh, poly = poly, curv = curv, quad = { -1, -1, 1, -1, 1, 1, -1, 1 }, hits = #P, tris = 0,
           top = true }
end

-- glass frame (relative to the vehicle position, world axes): c centre, r right, u up the glass, n normal; hw, hh half
-- kind (1.0 wiper model): 'front' = the windshield, 'rear' = the rear / hatch glass (pivot anywhere around the pane);
-- curv = the pane's bulge (see glassFromMesh), used to tell the blade lying on the glass from the arm above it
local function computeWipers(b, cR, rA, uA, nA, hw, hh, rhd, poly, kind, curv)
  local rear = (kind == 'rear')
  local vdata = vehicleData(b.id)
  local list = vdata and vdata.flexbodies
  if type(list) ~= 'table' then return { blades = {}, meshes = {}, note = 'no flexbody data' } end
  local toCar = jbeamMapper(b, vdata)
  if not toCar then return { blades = {}, meshes = {}, note = 'no reference nodes' } end
  local A, B, D, meshes = {}, {}, {}, {}
  local function bulge(a, v)
    if not curv then return 0 end
    a, v = clamp(a, -hw, hw), clamp(v, -hh, hh)
    return clamp(curv[1] + curv[2] * v + (curv[3] + curv[4] * v) * a * a, -0.15, 0.15)
  end
  for _, fb in pairs(list) do
    local name = type(fb) == 'table' and fb.mesh
    if type(name) == 'string' then
      local low = name:lower()
      if low:find('wiper', 1, true) and not low:find('stalk', 1, true) and not low:find('headlight', 1, true) then
        local obj = nil
        pcall(function() obj = fb.fid and b.veh:getFlexmesh(fb.fid) end)
        local n = 0
        if obj then pcall(function() n = obj:getVertexCount() end) end
        local used = 0
        if n > 0 then
          local step = math.max(1, math.floor(n / 6000))
          pcall(function()
            for i = 0, n - 1, step do
              local px, py, pz = toCar(obj:getInitVertexPos(i))   -- rest pose -> relative to the vehicle, world axes
              local dx, dy, dz = px - cR[1], py - cR[2], pz - cR[3]
              local d = dx * nA[1] + dy * nA[2] + dz * nA[3]
              local a = dx * rA[1] + dy * rA[2] + dz * rA[3]
              local v = dx * uA[1] + dy * uA[2] + dz * uA[3]
              -- on this windshield: close to the glass, not far above its middle (rear / headlight wipers drop out)
              local near
              if rear then near = math.abs(d) < 0.25 and math.abs(a) < hw * 1.4 and math.abs(v) < hh * 1.7
              else near = math.abs(d) < 0.30 and math.abs(a) < hw * 1.5 and v < hh * 0.6 and v > -hh * 1.8 end
              if near then
                A[#A + 1], B[#B + 1], D[#D + 1] = a, v, d - bulge(a, v)
                used = used + 1
              end
            end
          end)
        end
        if used > 0 then meshes[#meshes + 1] = name end
      end
    end
  end
  if #A < 20 then return { blades = {}, meshes = {}, note = 'no wiper mesh on this windshield' } end

  -- Blades. A wiper mesh is a dense pivot cap (spindle cover, most of the vertices: ~30-40 on a D15) and a sparse
  -- arm + blade running out from it (vertices 10-16 cm apart), so blades are found from their caps, not by contact:
  -- 1. 4 cm grid, cells by vertex count; the densest cell is a pivot, then the next densest that does not lie on a
  --    blade already found (blade tips are dense too, but sit on their own blade's line), up to 4 blades;
  -- 2. from each pivot, the direction (3 degree steps) that lines up the most vertices within 2.5 cm;
  -- 3. the blade runs out along it as long as consecutive vertices are less than 20 cm apart.
  local CELL, cnt = 0.04, {}
  for i = 1, #A do
    local k = math.floor(A[i] / CELL) .. ',' .. math.floor(B[i] / CELL)
    cnt[k] = (cnt[k] or 0) + 1
  end
  local cand = {}
  for k, c in pairs(cnt) do
    local ix, iy = k:match('^(-?%d+),(-?%d+)$')
    if ix then cand[#cand + 1] = { x = (tonumber(ix) + 0.5) * CELL, y = (tonumber(iy) + 0.5) * CELL, c = c } end
  end
  table.sort(cand, function(p, q) return p.c > q.c end)
  local top = cand[1] and cand[1].c or 0
  local found = {}
  local function onFoundBlade(x, y)
    for _, f in ipairs(found) do
      local dx, dy = x - f.px, y - f.py
      local t = dx * math.cos(f.ang) + dy * math.sin(f.ang)
      if t > -0.08 and t < f.len + 0.08 and math.abs(-dx * math.sin(f.ang) + dy * math.cos(f.ang)) < 0.05 then return true end
    end
    return false
  end
  for _, cd in ipairs(cand) do
    if #found >= 4 or cd.c < math.max(5, top * 0.3) then break end
    if not onFoundBlade(cd.x, cd.y) then
      local sx, sy, sn = 0, 0, 0
      for i = 1, #A do
        local dx, dy = A[i] - cd.x, B[i] - cd.y
        if dx * dx + dy * dy < 0.0036 then sx, sy, sn = sx + A[i], sy + B[i], sn + 1 end
      end
      local px, py = sx / math.max(sn, 1), sy / math.max(sn, 1)
      local bestAng, bestN = nil, 0
      for k = 0, 119 do
        local ang = k * math.pi / 60
        local ca, sa = math.cos(ang), math.sin(ang)
        local n = 0
        for i = 1, #A do
          local dx, dy = A[i] - px, B[i] - py
          local t = dx * ca + dy * sa
          if t > 0.06 and t < 1.1 and math.abs(-dx * sa + dy * ca) < 0.025 then n = n + 1 end
        end
        if n > bestN then bestAng, bestN = ang, n end
      end
      if bestAng and bestN >= 3 then
        local ca, sa = math.cos(bestAng), math.sin(bestAng)
        local ts = {}
        for i = 1, #A do
          local dx, dy = A[i] - px, B[i] - py
          local t = dx * ca + dy * sa
          if t > 0 and t < 1.2 and math.abs(-dx * sa + dy * ca) < 0.035 then ts[#ts + 1] = t end
        end
        table.sort(ts)
        local len = 0
        for _, t in ipairs(ts) do
          if t - len < 0.20 then len = t else break end
        end
        if len > 0.15 then found[#found + 1] = { px = px, py = py, ang = bestAng, len = len } end
      end
    end
  end
  if #found == 0 then return { blades = {}, meshes = meshes, note = 'no blade found in the wiper mesh' } end
  -- one wiper can show two dense spots (pivot cap + arm/blade joint): a shorter blade lying along a longer one is the
  -- same wiper (measured on a D15: its left wiper came out twice)
  table.sort(found, function(p, q) return p.len > q.len end)
  local kept = {}
  for _, f in ipairs(found) do
    local dup = false
    for _, k in ipairs(kept) do
      local da = math.abs(math.atan2(math.sin(f.ang - k.ang), math.cos(f.ang - k.ang)))
      local dx, dy = f.px - k.px, f.py - k.py
      local t = dx * math.cos(k.ang) + dy * math.sin(k.ang)
      local s = math.abs(-dx * math.sin(k.ang) + dy * math.cos(k.ang))
      if (da < math.rad(20) or da > math.rad(160)) and s < 0.07 and t > -0.12 and t < k.len + 0.12 then dup = true end
      if dx * dx + dy * dy < 0.04 then dup = true end            -- pivots closer than 20 cm
    end
    if not dup then kept[#kept + 1] = f end
  end
  found = kept
  -- a pivot sits on the cowl: if the far end is clearly lower, the dense end was the blade tip
  for _, f in ipairs(found) do
    local tx, ty = f.px + f.len * math.cos(f.ang), f.py + f.len * math.sin(f.ang)
    if not rear and ty < f.py - 0.03 then f.px, f.py, f.ang = tx, ty, f.ang + math.pi end
  end
  table.sort(found, function(p, q) return p.px < q.px end)    -- left to right
  -- 1.0 wiper model: where the rubber starts. The blade lies on the glass, the arm rises from it toward the pivot: going
  -- in from the tip, the blade ends at the last vertex that is still as close to the glass as the outer half of the
  -- blade is. Only a plausible result is used (18..45 % of the reach); otherwise the usual 28 % stands.
  local function bladeStart(f)
    local ca, sa = math.cos(f.ang), math.sin(f.ang)
    local pts, outer = {}, {}
    for i = 1, #A do
      local dx, dy = A[i] - f.px, B[i] - f.py
      local t = dx * ca + dy * sa
      if t > 0.05 and t < f.len + 0.02 and math.abs(-dx * sa + dy * ca) < 0.04 then
        pts[#pts + 1] = { t, D[i] }
        if t > f.len * 0.5 then outer[#outer + 1] = D[i] end
      end
    end
    if #pts < 12 or #outer < 6 then return nil end
    table.sort(outer)
    local base = outer[math.max(1, math.floor(#outer * 0.1))]
    local BIN, has = 0.04, {}
    for _, p in ipairs(pts) do if p[2] < base + 0.025 then has[math.floor(p[1] / BIN)] = true end end
    local start, gap = f.len, 0
    for k = math.floor(f.len / BIN), 0, -1 do
      if has[k] then start, gap = k * BIN, 0 else gap = gap + 1 if gap > 5 then break end end
    end
    if start >= f.len * 0.18 and start <= f.len * 0.45 then return start end
    return nil
  end
  -- the glass outline in metres (counter-clockwise), from the jbeam frame; the rectangle when there is none
  local P = {}
  if type(poly) == 'table' and #poly >= 6 then
    for k = 1, #poly - 1, 2 do P[#P + 1] = { poly[k] * hw, poly[k + 1] * hh } end
  else
    P = { { -hw, -hh }, { hw, -hh }, { hw, hh }, { -hw, hh } }
  end
  local function insideGlass(x, y, margin)
    for k = 1, #P do
      local p0, p1 = P[k], P[k % #P + 1]
      local ex, ey = p1[1] - p0[1], p1[2] - p0[2]
      local l = math.sqrt(ex * ex + ey * ey)
      if l > 1e-6 and (ex * (y - p0[2]) - ey * (x - p0[1])) / l < margin then return false end
    end
    return true
  end
  -- how far this blade sweeps: rotate from the parked angle until its tip has crossed the glass and reaches the far
  -- edge (pillar / roof), read from this car's own glass instead of a fixed angle
  local function sweepToGlassEdge(pa, pb, L, park, sgn)
    local step, entered = math.rad(2), false
    for k = 1, 85 do
      local a = park + sgn * k * step
      local ok = insideGlass(pa + L * math.cos(a), pb + L * math.sin(a), 0.04)
      if ok then entered = true
      elseif entered then return sgn * math.max((k - 1) * step, math.rad(45)) end
    end
    return entered and sgn * math.rad(150) or nil
  end

  local blades = {}
  for _, f in ipairs(found) do
    local pa, pb = f.px, f.py
    local park = math.atan2(math.sin(f.ang), math.cos(f.ang))
    local L = f.len
    -- sweep up into the glass: counter-clockwise when the blade points right, clockwise when it points left; the
    -- angle comes from this car's glass outline (a fixed 100 degrees only if the tip never reaches the glass)
    local sgn = (math.cos(park) >= 0) and 1 or -1
    if rear then
      -- a rear wiper can sit below, above or beside the glass: it sweeps the way that takes its tip toward the middle
      local tx, ty = pa + L * math.cos(park), pb + L * math.sin(park)
      sgn = ((-math.sin(park)) * (-tx) + math.cos(park) * (-ty) >= 0) and 1 or -1
    end
    local range = sweepToGlassEdge(pa, pb, L, park, sgn) or sgn * 1.75
    local okS, r0 = pcall(bladeStart, f)
    r0 = okS and r0 or nil
    blades[#blades + 1] = { pa / hh, pb / hh, park, range, (r0 or 0.28 * L) / hh, L / hh, 0, r0 and true or false }
  end
  -- Tandem blades (parallel when parked) share one linkage, so they sweep the same angle: the one whose tip meets the
  -- glass edge first sets it (on a D15 the left blade reaches the pillar at 84 deg; the right one never meets an
  -- edge). A single blade keeps its own sweep, capped at 150 deg.
  if #blades >= 2 then
    local minAbs, parallelAll = math.huge, true
    for i = 1, #blades do
      minAbs = math.min(minAbs, math.abs(blades[i][4]))
      local d = math.abs(math.atan2(math.sin(blades[i][3] - blades[1][3]), math.cos(blades[i][3] - blades[1][3])))
      if d > math.rad(20) then parallelAll = false end
    end
    for i = 1, #blades do
      local s = (blades[i][4] >= 0) and 1 or -1
      blades[i][4] = s * (parallelAll and minAbs or math.min(math.abs(blades[i][4]), math.rad(110)))
    end
  elseif #blades == 1 then
    local s = (blades[1][4] >= 0) and 1 or -1
    blades[1][4] = s * math.min(math.abs(blades[1][4]), math.rad(150))
  end
  return { blades = blades, meshes = meshes, note = string.format('%d blade(s) from the car\'s wiper mesh', #blades) }
end

-- 1.0 Animated Wipers bridge: that mod's blades are props driven by 'wiperVal' / 'wiperVal2', and each prop's rotation
-- is that blade's real sweep. Every measured blade takes the sweep of the nearest such prop (by pivot), so the glass
-- clears exactly as far as the animated blades go. Returns how many blades were changed (0 without that mod).
local wiperGeoR = {}   -- [vid] = rear-glass counterpart of wiperGeo (1.0 wiper model)
local measureWipers
do
local function wrapPi(x) return x - 2 * math.pi * math.floor((x + math.pi) / (2 * math.pi)) end

-- where on its arc (0..1) a blade is, 'phase' half sweeps into a cycle (cosine: the Animated Wipers easing)
local function easeAt(phase, cosine)
  local e = phase % 2
  if e > 1 then e = 2 - e end
  if cosine then return 0.5 - 0.5 * math.cos(math.pi * e) end
  return e * e * (3 - 2 * e)
end

-- funcs (1.0 wiper model): the electrics values to look for ({ wiperVal, wiperVal2 } windshield, { wiperValR } rear)
local function applyAnimatedWiperSweep(b, blades, cR, rA, uA, hh, funcs)
  funcs = funcs or { wiperVal = true, wiperVal2 = true }
  local vdata = vehicleData(b.id)
  if not (vdata and type(vdata.props) == 'table' and type(blades) == 'table' and #blades > 0) then return 0 end
  local toCar = jbeamMapper(b, vdata)
  if not toCar then return 0 end
  -- a blade driven by 'wiperVal2' rests part-way along its arc (that mod's public 'wiperOffset', in half sweeps)
  local awCfg = type(vdata.animatedWipers) == 'table' and vdata.animatedWipers or {}
  local awOffset = tonumber(awCfg.wiperOffset) or 0
  local byName = nil
  local function nodeOf(id)
    local nodes = vdata.nodes or {}
    if type(id) == 'number' then return nodes[id] end
    if type(id) ~= 'string' then return nil end
    if not byName then
      byName = {}
      for _, n in pairs(nodes) do if type(n) == 'table' and n.name then byName[n.name] = n end end
    end
    return byName[id]
  end
  local props = {}
  for _, p in pairs(vdata.props) do
    if type(p) == 'table' and type(p.func) == 'string' and funcs[p.func] and p.idRef ~= nil
       and (type(p.rotation) == 'table' or type(p.rotation) == 'cdata') then
      local r = p.rotation
      local rx = tonumber(r.x or r[1]) or 0
      local ry = tonumber(r.y or r[2]) or 0
      local rz = tonumber(r.z or r[3]) or 0
      local mag = math.sqrt(rx * rx + ry * ry + rz * rz)
      if mag > 2 * math.pi then mag = math.rad(mag) end          -- degrees (data not converted by the jbeam loader)
      local n = nodeOf(p.idRef)
      if mag > math.rad(20) and n and n.pos then
        local px, py, pz = toCar(n.pos)
        -- 1.0: the blade turns about its prop's origin, which need not be the reference node (measured on the ETK 800:
        -- the driver-side origin sits 0.33 m from its node). The live transform is relative to the vehicle position in
        -- world axes, like everything here; used when it lies on the car.
        local okT, o = pcall(function() return b.veh:getProp(p.pid):getLiveTransformWorld():getColumn(3) end)
        if okT and o and tonumber(o.x) and math.abs(o.x) < 6 and math.abs(o.y) < 8 and math.abs(o.z) < 5 then
          px, py, pz = o.x, o.y, o.z
        end
        local dx, dy, dz = px - cR[1], py - cR[2], pz - cR[3]
        props[#props + 1] = { a = (dx * rA[1] + dy * rA[2] + dz * rA[3]) / hh, v = (dx * uA[1] + dy * uA[2] + dz * uA[3]) / hh,
                              mag = mag, phase = (p.func == 'wiperVal2') and awOffset or 0 }
      end
    end
  end
  if #props == 0 then return 0 end
  -- 1.0 wiper model. Each blade found in the mesh is paired with the pivot nearest one of its ends, all pairs together
  -- (the best overall assignment). A pivot at the far end of a blade means the mesh's dense end was the tip: that
  -- blade is turned round (measured on the ETK 800: its driver-side blade came out reversed). Pairs within ~0.6 glass
  -- half heights; a lone blade takes a lone prop wherever it sits.
  local nB, nP = #blades, #props
  local ends = {}
  for bi, bl in ipairs(blades) do
    ends[bi] = { bl[1], bl[2], bl[1] + bl[6] * math.cos(bl[3]), bl[2] + bl[6] * math.sin(bl[3]) }
  end
  local function endDist2(e, px, py)
    local d0 = (e[1] - px) ^ 2 + (e[2] - py) ^ 2
    local d1 = (e[3] - px) ^ 2 + (e[4] - py) ^ 2
    if d1 < d0 then return d1, true end
    return d0, false
  end
  local lone = (nP == 1 and nB == 1)
  local bestScore, bestMap = math.huge, nil
  local map, used = {}, {}
  local function try(bi, cost, matched)
    if bi > nB then
      local score = cost - matched * 100                          -- as many pairs as possible, then the closest
      if score < bestScore then
        bestScore, bestMap = score, {}
        for k = 1, nB do bestMap[k] = map[k] end
      end
      return
    end
    map[bi] = false
    try(bi + 1, cost, matched)
    for pk = 1, nP do
      if not used[pk] then
        local d = endDist2(ends[bi], props[pk].a, props[pk].v)
        if d < 0.36 or lone then
          used[pk], map[bi] = true, pk
          try(bi + 1, cost + d, matched + 1)
          used[pk], map[bi] = false, false
        end
      end
    end
  end
  try(1, 0, 0)
  local changed = 0
  for bi = 1, nB do
    local pk = bestMap and bestMap[bi]
    if pk then
      local bl, pr = blades[bi], props[pk]
      local _, atTip = endDist2(ends[bi], pr.a, pr.v)
      local sgn = (bl[4] >= 0) and 1 or -1
      if atTip then
        bl[3] = wrapPi(bl[3] + math.pi)
        bl[5], bl[8] = 0.28 * bl[6], false                        -- the rubber start was measured from the wrong end
      end
      bl[1], bl[2] = pr.a, pr.v
      if atTip then
        -- it sweeps the way that takes its tip toward the middle of the glass
        local tx, ty = bl[1] + bl[6] * math.cos(bl[3]), bl[2] + bl[6] * math.sin(bl[3])
        sgn = ((-math.sin(bl[3])) * (-tx) + math.cos(bl[3]) * (-ty) >= 0) and 1 or -1
      end
      local sweep = sgn * math.min(pr.mag, math.rad(170))
      if pr.phase ~= 0 then
        bl[3] = bl[3] - sweep * easeAt(pr.phase, true)              -- the mesh shows the blade where it rests
        bl[7] = pr.phase
      end
      bl[4] = sweep
      changed = changed + 1
    end
  end
  return changed
end

-- Wiper model (1.0) ----------------------------------------------------------------------------------------------------
-- One measured description of a car's wipers per pane, used by everything: the clearing in the shader, the rain
-- sensor, the status line and extensions.rainPuddles.getWiperModel(). Per blade: pivot, reach (inner / outer), parked
-- angle, signed sweep, the part of the glass it sweeps (its ring sector cut to the real glass outline) and how far its
-- tip travels. Per pane: the share of the glass that gets wiped at all, the overlap of the blades and the zones no
-- blade reaches. Areas are counted on a grid over the glass outline, once per car.
-- Sources, best first: the Animated Wipers mod's blades (sweep and resting point from its props), the car's own wiper
-- mesh, the procedural tandem pair. A source whose result is not believable (too little or too much of the glass
-- swept, a pivot far off the glass, an impossible blade) is dropped with a log line and the next one is used.

-- blades: { pivot x, pivot y, parked angle, signed sweep, inner radius, outer radius, phase } in glass half heights
local function buildWiperModel(pr, blades, kind, source)
  local hw, hh = pr.hw, pr.hh
  local P = {}
  if type(pr.poly) == 'table' and #pr.poly >= 6 then
    for k = 1, #pr.poly - 1, 2 do P[#P + 1] = { pr.poly[k] * hw, pr.poly[k + 1] * hh } end
  else
    P = { { -hw, -hh }, { hw, -hh }, { hw, hh }, { -hw, hh } }
  end
  local function inside(x, y)
    for k = 1, #P do
      local p0, p1 = P[k], P[k % #P + 1]
      if (p1[1] - p0[1]) * (y - p0[2]) - (p1[2] - p0[2]) * (x - p0[1]) < 0 then return false end
    end
    return true
  end
  local NX, NY = 72, 44
  local cell = (2 * hw / NX) * (2 * hh / NY)
  local nGlass, nUnion, nOver = 0, 0, 0
  local per, zone = {}, {}
  for i = 1, #blades do per[i] = 0 end
  for i = 1, 9 do zone[i] = { 0, 0 } end                         -- 3 x 3 zones: { glass cells, wiped cells }
  for iy = 0, NY - 1 do
    local y = -hh + (iy + 0.5) * 2 * hh / NY
    for ix = 0, NX - 1 do
      local x = -hw + (ix + 0.5) * 2 * hw / NX
      if inside(x, y) then
        nGlass = nGlass + 1
        local hits = 0
        for i, bl in ipairs(blades) do
          local dx, dy = x - bl[1] * hh, y - bl[2] * hh
          local rho = math.sqrt(dx * dx + dy * dy)
          if rho > bl[5] * hh and rho < bl[6] * hh and math.abs(bl[4]) > 1e-3 then
            local t = wrapPi(math.atan2(dy, dx) - bl[3]) / bl[4]
            if t >= 0 and t <= 1 then hits = hits + 1; per[i] = per[i] + 1 end
          end
        end
        local z = zone[math.min(2, math.floor(iy * 3 / NY)) * 3 + math.min(2, math.floor(ix * 3 / NX)) + 1]
        z[1] = z[1] + 1
        if hits > 0 then nUnion = nUnion + 1; z[2] = z[2] + 1 end
        if hits > 1 then nOver = nOver + 1 end
      end
    end
  end
  if nGlass < 20 then return nil end
  local m = { source = source, kind = kind, valid = true, glassArea = nGlass * cell, glassWidth = 2 * hw, glassHeight = 2 * hh,
              coverage = nUnion / nGlass, coveredArea = nUnion * cell, overlap = nOver / nGlass, overlapArea = nOver * cell,
              blades = {}, unwiped = {} }
  for i, bl in ipairs(blades) do
    local r0, r1, sw = bl[5] * hh, bl[6] * hh, bl[4]
    m.blades[i] = { pivotX = bl[1] * hh, pivotY = bl[2] * hh, park = bl[3], sweep = sw, phase = bl[7] or 0,
                    reachInner = r0, reachOuter = r1, bladeLength = r1 - r0, bladeStartMeasured = bl[8] and true or false,
                    sectorArea = 0.5 * math.abs(sw) * (r1 * r1 - r0 * r0), sweptArea = per[i] * cell,
                    sweptShare = per[i] / nGlass, tipArc = r1 * math.abs(sw) }
  end
  -- zones a blade hardly reaches (rows from the bottom of the glass, columns from the car's left)
  local rows, cols = { 'bottom', 'middle', 'top' }, { 'left', 'centre', 'right' }
  for r = 0, 2 do
    for c = 0, 2 do
      local z = zone[r * 3 + c + 1]
      if z[1] > nGlass * 0.03 and z[2] / z[1] < 0.5 then
        m.unwiped[#m.unwiped + 1] = { zone = rows[r + 1] .. ' ' .. cols[c + 1], wiped = z[2] / z[1], area = (z[1] - z[2]) * cell }
      end
    end
  end
  table.sort(m.unwiped, function(p, q) return p.area > q.area end)
  -- is this believable?
  local why = nil
  -- a single blade really does leave most of a windshield (measured: the Pigeon's one blade wipes 32 % of its glass)
  local lo = (kind == 'rear') and 0.15 or ((#blades == 1) and 0.20 or 0.35)
  if #blades == 0 then why = 'no blades'
  elseif m.coverage < lo then why = string.format('only %.0f %% of the glass would be swept', m.coverage * 100)
  elseif m.coverage > 0.98 then why = string.format('%.0f %% of the glass would be swept', m.coverage * 100) end
  for i, bl in ipairs(m.blades) do
    if math.abs(bl.pivotX) > hw + 0.45 or math.abs(bl.pivotY) > hh + 0.6 then
      why = why or string.format('the pivot of blade %d is far off the glass', i)
    end
    if bl.reachOuter < 0.12 or bl.reachOuter > 1.3 then
      why = why or string.format('blade %d would reach %.2f m', i, bl.reachOuter)
    end
  end
  if why then m.valid, m.why = false, why end
  return m
end

-- the procedural tandem pair in the shader's numbers (rp_windshield.cs.hlsl: RP_PIVOT0 / 1, RP_BLADE_R0 / 1, WIPER)
local function proceduralBlades(aspect, rhd)
  local side = rhd and -1 or 1
  local pk = rhd and (math.pi - 0.06) or 0.06
  return { { -0.30 * aspect * side, -1.06, pk, 1.75 * side, 0.16, 1.72, 0 },
           { 0.55 * aspect * side, -1.06, pk, 1.75 * side, 0.16, 1.72, 0 } }
end

local SOURCE_TEXT = { animatedWipers = 'Animated Wipers blades', mesh = "the car's wiper mesh", procedural = 'generic tandem pair' }

local function wiperModelNote(m)
  if not m then return 'no wipers' end
  local sw, r0, r1 = {}, math.huge, 0
  for _, bl in ipairs(m.blades) do
    sw[#sw + 1] = string.format('%.0f', math.deg(math.abs(bl.sweep)))
    r0, r1 = math.min(r0, bl.reachInner), math.max(r1, bl.reachOuter)
  end
  return string.format('%d blade%s (%s), sweep %s deg, reach %.2f-%.2f m, %.0f %% of the %.2f m2 glass wiped',
    #m.blades, #m.blades == 1 and '' or 's', SOURCE_TEXT[m.source] or tostring(m.source), table.concat(sw, ' / '), r0, r1,
    m.coverage * 100, m.glassArea)
end

-- pr = the pane (vehicle-local result with hw, hh, poly, curv), frame = its centre and axes relative to the vehicle
function measureWipers(b, pr, kind, cR, rA, uA, nA, rhd)
  local funcs = (kind == 'rear') and { wiperValR = true } or { wiperVal = true, wiperVal2 = true }
  local okW, res = pcall(computeWipers, b, cR, rA, uA, nA, pr.hw, pr.hh, rhd, pr.frame and pr.poly or nil, kind,
    (pr.frame and type(pr.curv) == 'table' and #pr.curv == 4) and pr.curv or nil)
  local geo = (okW and type(res) == 'table') and res or { blades = {}, meshes = {}, note = 'wiper scan failed: ' .. tostring(res) }
  local dropped, model = {}, nil
  if #geo.blades > 0 then
    local fromMesh = {}
    for i, bl in ipairs(geo.blades) do fromMesh[i] = { bl[1], bl[2], bl[3], bl[4], bl[5], bl[6], bl[7] or 0, bl[8] } end
    local okA, nAW = pcall(applyAnimatedWiperSweep, b, geo.blades, cR, rA, uA, pr.hh, funcs)
    if okA and (nAW or 0) > 0 then
      local okM, m = pcall(buildWiperModel, pr, geo.blades, kind, 'animatedWipers')
      if okM and m and m.valid then model = m
      else
        dropped[#dropped + 1] = 'Animated Wipers data: ' .. tostring(okM and m and m.why or m)
        geo.blades = fromMesh
      end
    end
    if not model then
      local okM, m = pcall(buildWiperModel, pr, geo.blades, kind, 'mesh')
      if okM and m and m.valid then model = m
      else
        dropped[#dropped + 1] = 'wiper mesh: ' .. tostring(okM and m and m.why or m)
        geo.blades = {}
      end
    end
  else
    dropped[#dropped + 1] = tostring(geo.note)
  end
  if not model and kind ~= 'rear' then
    geo.blades = proceduralBlades(pr.hw / pr.hh, rhd)
    local okM, m = pcall(buildWiperModel, pr, geo.blades, kind, 'procedural')
    if okM and m then
      m.valid, m.why = true, nil                                  -- the last resort is used as it is
      model = m
    end
  end
  geo.model = model
  geo.dropped = dropped
  geo.note = wiperModelNote(model) .. ((#dropped > 0) and ('; not used: ' .. table.concat(dropped, '; ')) or '')
  return geo
end
end -- do (wiper model helpers)

-- hides / shows the car's parked wiper meshes (only ever the meshes the mod itself measured)
local function setWiperMeshesHidden(b, hide)
  if not b then return end
  local vid = b.id
  local geo = wiperGeo[vid]
  if hide and geo and #geo.blades > 0 and #geo.meshes > 0 then
    if not wiperHidden[vid] then
      for _, name in ipairs(geo.meshes) do pcall(function() b.veh:setMeshAlpha(0, name, false) end) end
      wiperHidden[vid] = geo.meshes
    end
  elseif wiperHidden[vid] then
    for _, name in ipairs(wiperHidden[vid]) do pcall(function() b.veh:setMeshAlpha(1, name, false) end) end
    wiperHidden[vid] = nil
  end
end

local function restoreAllWiperMeshes()
  for vid, names in pairs(wiperHidden) do
    local veh = nil
    pcall(function() veh = scenetree.findObjectById(vid) end)
    if veh then for _, name in ipairs(names) do pcall(function() veh:setMeshAlpha(1, name, false) end) end end
  end
  wiperHidden = {}
end

local function buildWindshield()
  windshield, rearGlass = nil, nil
  SIDE.L, SIDE.R = nil, nil
  if next(wiperHidden) then restoreAllWiperMeshes() end        -- (older builds hid the parked 3D wipers)
  -- 1.0: also from outside the car (the player's car only), once its real glass is known
  local inside = cam.cockpit
  if not (S.enabled and S.windshield and playerBox and (inside or S.windshieldOutside)) then return end
  local b = playerBox
  if inside then
    -- 1.0: probe only once the in-car camera has settled. The first probe used to fire during the camera transition,
    -- from an eye position somewhere between the orbit camera and the seat, and fitted the glass to the wrong
    -- surfaces. Also only while the car is (nearly) still, so the camera and the node positions agree.
    if T - (cam.cockpitSince or -1e9) > 1.0 and (b.speed or 0) < 4.0 then requestWindshieldProbe(b) end
  else
    requestWindshieldProbe(b, true)                            -- the jbeam frame does not need the driver's eye
  end
  -- right-hand drive (game data): the wipers are mirrored
  local rhd = false
  if core_camera and type(core_camera.getDriverDataById) == 'function' then
    local okD, _, r = pcall(core_camera.getDriverDataById, b.id)
    rhd = okD and r == true or false
  end

  -- Axes: live vehicle basis when available, OBB axes as fallback. Re-orthonormalised.
  local fx, fy, fz = vecCall(b.veh, 'getDirectionVector')
  local ux, uy, uz = vecCall(b.veh, 'getDirectionVectorUp')
  if not (fx and ux) then
    -- BeamNG vehicle +Y points backward, so the forward vector is -OBB axis 1.
    fx, fy, fz = -b.a1[1], -b.a1[2], -b.a1[3]
    ux, uy, uz = b.a2[1], b.a2[2], b.a2[3]
  end
  fx, fy, fz = norm3(fx, fy, fz)
  -- Remove any numerical component of up along forward before rebuilding the basis.
  local fu = dot3(fx, fy, fz, ux, uy, uz)
  ux, uy, uz = norm3(ux - fx * fu, uy - fy * fu, uz - fz * fu)
  local rx, ry, rz = norm3(fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux)  -- right = fwd x up
  ux, uy, uz = norm3(ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx)         -- up = right x fwd

  local function w(l) return rx * l[1] + fx * l[2] + ux * l[3], ry * l[1] + fy * l[2] + uy * l[3], rz * l[1] + fz * l[2] + uz * l[3] end

  -- 1.0: the car's own glass meshes (exact outline and curve of the windshield and of the rear / hatch glass), read
  -- once per car; the jbeam frame / ray probe stay the fallback for cars without a recognisable windshield mesh
  local gm = glassMesh[b.id]
  if gm and gm.retryAt and T >= gm.retryAt then gm = nil end
  if gm == nil then
    local F, U, R = { fx, fy, fz }, { ux, uy, uz }, { rx, ry, rz }
    local okF, rf, whyF = pcall(glassFromMesh, b, 'front', F, U, R)
    local okB, rb, whyB = pcall(glassFromMesh, b, 'rear', F, U, R)
    local okL, rsL = pcall(glassFromMesh, b, 'sideL', F, U, R)
    local okR, rsR = pcall(glassFromMesh, b, 'sideR', F, U, R)
    local tries = (glassMesh[b.id] and glassMesh[b.id].tries or 0) + 1
    gm = { front = (okF and rf) or false, rear = (okB and rb) or false, tries = tries,
           sideL = (okL and rsL) or false, sideR = (okR and rsR) or false }
    -- not settled yet (car spawning / being reloaded): read again in a second, a few times
    if ((okF and whyF == 'retry') or (okB and whyB == 'retry')) and tries < 8 then gm.retryAt = T + 1.0 end
    glassMesh[b.id] = gm
    if not gm.retryAt then log('I', TAG, string.format('glass meshes on vehicle %d: windshield %s, rear %s, side %s / %s', b.id,
      gm.front and (gm.front.mesh .. string.format(' (%.2f x %.2f m)', gm.front.hw * 2, gm.front.hh * 2)) or 'none',
      gm.rear and (gm.rear.mesh .. string.format(' (%.2f x %.2f m)', gm.rear.hw * 2, gm.rear.hh * 2)) or 'none',
      gm.sideL and string.format('%s (%.2f x %.2f m)', gm.sideL.mesh, gm.sideL.hw * 2, gm.sideL.hh * 2) or 'none',
      gm.sideR and string.format('%s (%.2f x %.2f m)', gm.sideR.mesh, gm.sideR.hw * 2, gm.sideR.hh * 2) or 'none')) end
  end
  if gm.rear and S.rearGlass then
    local g = gm.rear
    local ccx, ccy, ccz = w(g.c)
    local nnx, nny, nnz = w(g.n)
    local rrx, rry, rrz = w(g.r)
    local uux, uuy, uuz = w(g.u)
    rearGlass = {
      cx = b.px + ccx, cy = b.py + ccy, cz = b.pz + ccz,
      nx = nnx, ny = nny, nz = nnz, rx = rrx, ry = rry, rz = rrz, ux = uux, uy = uuy, uz = uuz,
      halfW = g.hw, halfH = g.hh, probed = true, quad = g.quad, poly = g.poly, curv = g.curv,
    }
    -- 1.0 wiper model: the rear wiper (the Animated Wipers rear blade, or the car's own rear wiper mesh)
    local geoR = wiperGeoR[b.id]
    if not geoR or geoR.probe ~= g then
      geoR = measureWipers(b, g, 'rear', { ccx, ccy, ccz }, { rrx, rry, rrz }, { uux, uuy, uuz }, { nnx, nny, nnz }, false)
      geoR.probe = g
      wiperGeoR[b.id] = geoR
      log('I', TAG, 'rear wiper on vehicle ' .. b.id .. ': ' .. tostring(geoR.note))
    end
    rearGlass.blades = (S.rearWiper and geoR.model and #geoR.blades > 0) and geoR.blades or nil
  end
  -- 1.0 side windows, one pane per side
  if S.sideGlass then
    for _, sd in ipairs({ 'L', 'R' }) do
      local g = gm['side' .. sd]
      if g then
        local ccx, ccy, ccz = w(g.c)
        local nnx, nny, nnz = w(g.n)
        local rrx, rry, rrz = w(g.r)
        local uux, uuy, uuz = w(g.u)
        SIDE[sd] = { cx = b.px + ccx, cy = b.py + ccy, cz = b.pz + ccz, nx = nnx, ny = nny, nz = nnz,
                     rx = rrx, ry = rry, rz = rrz, ux = uux, uy = uuy, uz = uuz,
                     halfW = g.hw, halfH = g.hh, probed = true, quad = g.quad, poly = g.poly, curv = g.curv }
      end
    end
  end

  -- Probed glass: vehicle-local result -> world, with the car's current basis and position.
  local pr = gm.front or windProbe[b.id]
  if pr and pr.ok then
    local ccx, ccy, ccz = w(pr.c)
    local nnx, nny, nnz = w(pr.n)
    local rrx, rry, rrz = w(pr.r)
    local uux, uuy, uuz = w(pr.u)
    -- 1.0: this car's own wipers, measured once per probe from its wiper mesh
    local geo = wiperGeo[b.id]
    if not geo or geo.probe ~= pr then
      -- 1.0 wiper model: measured, checked, and the next source used when a result is not believable
      geo = measureWipers(b, pr, 'front', { ccx, ccy, ccz }, { rrx, rry, rrz }, { uux, uuy, uuz }, { nnx, nny, nnz }, rhd)
      geo.probe = pr
      wiperGeo[b.id] = geo
      log('I', TAG, 'wipers on vehicle ' .. b.id .. ': ' .. tostring(geo.note))
    end
    windshield = {
      cx = b.px + ccx, cy = b.py + ccy, cz = b.pz + ccz,
      nx = nnx, ny = nny, nz = nnz, rx = rrx, ry = rry, rz = rrz, ux = uux, uy = uuy, uz = uuz,
      halfW = pr.hw, halfH = pr.hh, probed = true, rhd = rhd,
      quad = (pr.frame and type(pr.quad) == 'table' and #pr.quad == 8) and pr.quad or nil,
      poly = (pr.frame and type(pr.poly) == 'table' and #pr.poly >= 6) and pr.poly or nil,     -- 1.0 glass outline
      curv = (pr.frame and type(pr.curv) == 'table' and #pr.curv == 4) and pr.curv or nil,     -- 1.0 glass bulge
      blades = (#geo.blades > 0) and geo.blades or nil,                                          -- 1.0 real wipers
    }
    return
  end
  -- outside the car there is no estimate: it is placed relative to the driver's eye
  if not inside then return end

  -- Estimate (probe not available / failed): raked glass from the OBB. Normal tilts up from forward.
  local c, s = math.cos(WIND.rake), math.sin(WIND.rake)
  local nx, ny, nz = fx * c + ux * s, fy * c + uy * s, fz * c + uz * s
  local px, py, pz = ux * c - fx * s, uy * c - fy * s, uz * c - fz * s

  -- OBB half extents (h[1] width, h[2] length, h[3] height) place the plane.
  local cx = b.cx + fx * (WIND.fwdK * b.h[2]) + ux * (WIND.upK * b.h[3])
  local cy = b.cy + fy * (WIND.fwdK * b.h[2]) + uy * (WIND.upK * b.h[3])
  local cz = b.cz + fz * (WIND.fwdK * b.h[2]) + uz * (WIND.upK * b.h[3])

  -- Rigid glass: keep the plane a believable distance in front of the eye point.
  local d = dot3(cx - cam.x, cy - cam.y, cz - cam.z, nx, ny, nz)
  local dc = clamp(d, WIND.minD, WIND.maxD)
  cx, cy, cz = cx + nx * (dc - d), cy + ny * (dc - d), cz + nz * (dc - d)

  windshield = {
    cx = cx, cy = cy, cz = cz, nx = nx, ny = ny, nz = nz,
    rx = rx, ry = ry, rz = rz, ux = px, uy = py, uz = pz,
    halfW = math.max(0.35, b.h[1] * 0.80),
    halfH = math.max(0.25, 0.45 * b.h[3] / c),
    rhd = rhd,
  }
end

-- tyres / splash screen-space samples --------------------------------------------------------

local function castGround(x, y, z, upx, upy, upz)
  if type(castRayStatic) ~= 'function' then return z - 0.32 end
  local sx, sy, sz = x + upx * 0.8, y + upy * 0.8, z + upz * 0.8
  local ok, dist = pcall(castRayStatic, vec3(sx, sy, sz), vec3(0, 0, -1), 2.4)
  if ok and type(dist) == 'number' and dist > 0.01 and dist < 2.39 then
    return sz - dist
  end
  return z - 0.32
end

-- tyres (0.9) ---------------------------------------------------------------------------------------------------------
-- Up to 8 tyres, the player's car first, then the nearest other vehicles: world-space contact point, travel direction,
-- ground speed, tread speed (spin, from vehicle Lua), half width, radius and an integrated spray clock per tyre. Used by
-- the spray pass (3D plume, depth-tested per puff) and the puddle pass (tyre wakes).
local MAX_TYRES = 8
local tyreClock = {}      -- ['vid:i'] = spray clock (integrated, so speed changes never make the puffs jump)
local wheelSpin = {}      -- [vid] = { [wheel index] = tread speed m/s, at = time }
local spinAsk = {}        -- [vid] = time of the last request

local function boxContains(b, x, y, z, margin)
  local dx, dy, dz = x - b.cx, y - b.cy, z - b.cz
  return math.abs(dx * b.a0[1] + dy * b.a0[2] + dz * b.a0[3]) <= b.h[1] + margin
     and math.abs(dx * b.a1[1] + dy * b.a1[2] + dz * b.a1[3]) <= b.h[2] + margin
     and math.abs(dx * b.a2[1] + dy * b.a2[2] + dz * b.a2[3]) <= b.h[3] + margin
end

-- World position of a node. getAbsNodePosition when the build has it; otherwise getNodePosition, which is relative to the
-- vehicle position (world axes, as in vehicle Lua). 0.8 rotated that offset through the box axes again, which is only right
-- for a car facing world +Y: now both readings are tried and the one that lies inside the car's box is used.
local function nodeWorld(b, nodeId)
  if nodeId == nil then return nil end
  local veh = b.veh
  -- 1.0: getNodeAbsPositionXYZ is the GE call the game itself uses (camera.lua); moved back by the same one-frame
  -- shift as the box (see readBox), so the tyres sit where the drawn wheels are.
  local okAbs, ax, ay, az = pcall(function() return veh:getNodeAbsPositionXYZ(nodeId) end)
  if okAbs and type(ax) == 'number' and type(ay) == 'number' and type(az) == 'number' then
    ax, ay, az = ax - (b.lagX or 0), ay - (b.lagY or 0), az - (b.lagZ or 0)
    if boxContains(b, ax, ay, az, 0.6) then return ax, ay, az end
  end
  local okN, np = pcall(function() return veh:getNodePosition(nodeId) end)
  if not okN or not np or not np.x then return nil end
  local x, y, z = b.px + np.x, b.py + np.y, b.pz + np.z
  if boxContains(b, x, y, z, 0.6) then return x, y, z end
  local a0, a1, a2 = b.a0, b.a1, b.a2
  x = b.px + a0[1] * np.x + a1[1] * np.y + a2[1] * np.z
  y = b.py + a0[2] * np.x + a1[2] * np.y + a2[2] * np.z
  z = b.pz + a0[3] * np.x + a1[3] * np.y + a2[3] * np.z
  if boxContains(b, x, y, z, 0.6) then return x, y, z end
  return nil
end

local function addTyresOf(b, list)
  local veh = b.veh
  local speed = b.speed or 0
  -- travel direction: velocity, or the heading when nearly stopped (wheelspin still throws water backward)
  local fx, fy = vecCall(veh, 'getDirectionVector')
  if not fx then fx, fy = -b.a1[1], -b.a1[2] end
  local dx, dy = fx, fy
  local hl = math.sqrt(dx * dx + dy * dy)
  if hl > 1e-4 then dx, dy = dx / hl, dy / hl end
  local vl = math.sqrt(b.vx * b.vx + b.vy * b.vy)
  if speed > 0.8 and vl > 1e-3 then dx, dy = b.vx / vl, b.vy / vl end
  local ux, uy, uz = b.a2[1], b.a2[2], b.a2[3]
  local spin = wheelSpin[b.id]
  if spin and T - (spin.at or -1e9) > 0.6 then spin = nil end      -- stale: use the ground speed
  local okC, count = pcall(function() return veh:getWheelCount() end)
  count = (okC and tonumber(count)) or 0
  local found = 0
  for i = 0, math.min(count, 6) - 1 do
    if #list >= MAX_TYRES then return end
    local okA, axis = pcall(function() return veh:getWheelAxisNodes(i) end)
    if okA and type(axis) == 'table' and axis[1] then
      local x1, y1, z1 = nodeWorld(b, axis[1])
      local x2, y2, z2 = nodeWorld(b, axis[2])
      if x1 then
        local wx, wy, wz, hw = x1, y1, z1, 0.11
        if x2 then
          wx, wy, wz = (x1 + x2) * 0.5, (y1 + y2) * 0.5, (z1 + z2) * 0.5
          hw = clamp(len3(x2 - x1, y2 - y1, z2 - z1) * 0.5, 0.07, 0.25)   -- hub span ~ tread width
        end
        local gz = castGround(wx, wy, wz, ux, uy, uz)
        found = found + 1
        list[#list + 1] = { x = wx, y = wy, z = gz, hw = hw, r = clamp(wz - gz, 0.18, 0.8), dx = dx, dy = dy,
                            g = speed, s = (spin and tonumber(spin[i])) or speed, key = b.id .. ':' .. i,
                            seed = (b.seed + i * 0.137) % 1, vid = b.id }
      end
    end
  end
  if found == 0 then
    -- no wheel data on this build / vehicle: four contact points estimated from the box
    for k, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
      if #list >= MAX_TYRES then return end
      local lx, ly = c[1] * math.max(b.h[1] - 0.22, 0.3), c[2] * b.h[2] * 0.62
      local wx = b.cx + b.a0[1] * lx + b.a1[1] * ly
      local wy = b.cy + b.a0[2] * lx + b.a1[2] * ly
      local wz = b.cz + b.a0[3] * lx + b.a1[3] * ly
      list[#list + 1] = { x = wx, y = wy, z = castGround(wx, wy, wz, ux, uy, uz), hw = 0.11, r = 0.33, dx = dx, dy = dy,
                          g = speed, s = speed, key = b.id .. ':b' .. k, seed = (b.seed + k * 0.211) % 1, vid = b.id }
    end
  end
end

local function collectTyres(dt)
  wheels = {}
  if not (S.enabled and (S.splashes or S.tyreWakes > 0.001) and groundWetness() > 0.02) then return end
  -- the player's car first (not from its own cabin), then the nearest other vehicles within 60 m
  for pass = 1, 2 do
    for i = 1, #boxes do
      local b = boxes[i]
      local isPlayer = (b == playerBox)
      if (pass == 1 and isPlayer and not (b.inside and cam.cockpit))
         or (pass == 2 and not isPlayer and S.trafficSpray and (b.d2 or 1e9) < 3600) then
        addTyresOf(b, wheels)
      end
    end
  end
  -- spray clocks, and ask the vehicles for their tread speeds (10 Hz)
  local seen = {}
  dt = math.max(tonumber(dt) or 0, 0)
  for _, t in ipairs(wheels) do
    local v = math.max(t.g, t.s)
    tyreClock[t.key] = ((tyreClock[t.key] or (t.seed * 7.0)) + dt * (0.9 + 0.075 * v)) % 4096
    t.clock = tyreClock[t.key]
    seen[t.key] = true
    if T - (spinAsk[t.vid] or -1e9) > 0.1 then
      spinAsk[t.vid] = T
      for i = 1, #boxes do
        if boxes[i].id == t.vid then
          pcall(function() boxes[i].veh:queueLuaCommand(string.format(
            "if not rainPuddlesProbe then extensions.load('rainPuddlesProbe') end if rainPuddlesProbe and rainPuddlesProbe.reportWheels then rainPuddlesProbe.reportWheels(%d) end", t.vid)) end)
          break
        end
      end
    end
  end
  for k in pairs(tyreClock) do if not seen[k] then tyreClock[k] = nil end end
end

local setTyreConsts
do
local EMPTY_TYRE_A, EMPTY_TYRE_B, EMPTY_TYRE_C = '0 0 -100000 0', '0 1 0 0', '0 0 0 0'
function setTyreConsts(fx)
  for i = 0, MAX_TYRES - 1 do
    local t = wheels[i + 1]
    if t then
      fx:setShaderConst('$rpTyreA' .. i, fmt4(t.x, t.y, t.z, t.hw))
      fx:setShaderConst('$rpTyreB' .. i, fmt4(t.dx, t.dy, t.g, t.s))
      -- y (1.0): 0.5 + 0.5 x how wet the road is there (dry under a roof / in a tunnel = 0.5: no spray, no wake)
      fx:setShaderConst('$rpTyreC' .. i, fmt4(t.r, 1 - 0.5 * rainSt.coveredAt(t.x, t.y, t.z), t.clock or 0, t.seed))
    else
      fx:setShaderConst('$rpTyreA' .. i, EMPTY_TYRE_A)
      fx:setShaderConst('$rpTyreB' .. i, EMPTY_TYRE_B)
      fx:setShaderConst('$rpTyreC' .. i, EMPTY_TYRE_C)
    end
  end
end
end -- do (tyre constants)

-- native precipitation ----------------------------------------------------------------------

local function setObjField(obj, field, value)
  pcall(function() obj:setField(field, 0, tostring(value)) end)
end

local function setNumDrops(obj, n)
  n = math.max(0, round(n))
  -- Property assignment is the path core_environment uses; the setField call
  -- covers builds where the property is exposed but read-only.
  pcall(function() obj.numDrops = n end)
  setObjField(obj, 'numDrops', n)
end

local function deleteObject(name)
  local o = scenetree.findObject(name)
  if o then pcall(function() o:delete() end) end
end

local function findExistingPrecip()
  local ok, list = pcall(function() return scenetree.findClassObjects('Precipitation') end)
  if not ok or type(list) ~= 'table' then return nil, nil end
  local best, bestName, bestD2 = nil, nil, math.huge
  for _, n in ipairs(list) do
    if n ~= PRECIP_HEAVY and n ~= PRECIP_FINE then
      local o = scenetree.findObject(n)
      if o then
        local pos = nil
        pcall(function() pos = o:getPosition() end)
        local d2 = 0
        if pos then
          local dx, dy, dz = pos.x - cam.x, pos.y - cam.y, pos.z - cam.z
          d2 = dx * dx + dy * dy + dz * dz
        end
        if d2 < bestD2 then
          best, bestName, bestD2 = o, n, d2
        end
      end
    end
  end
  return best, bestName
end

local function rememberOrig(obj, name)
  if precip.orig or not obj then return end
  precip.orig = {}
  for _, field in ipairs({ 'numDrops', 'dropSize', 'splashSize', 'boxWidth', 'boxHeight', 'splashMS', 'position' }) do
    local ok, value = pcall(function() return obj[field] end)
    if not ok then value = nil end
    precip.orig[field] = value
  end
  precip.existingName = name
end

local function createManagedPrecip(name, dataBlock)
  local root = scenetree.findObject('MissionGroup')
  if not root then return nil end
  if not scenetree.findObject(dataBlock) then
    warnOnce('dep_' .. dataBlock, 'native rain skipped: core datablock "' .. dataBlock .. '" not available')
    return nil
  end

  local obj = nil
  local ok = pcall(function() obj = createObject('Precipitation') end)
  if not ok or not obj then
    warnOnce('precip_class', 'native rain skipped: Precipitation class was not created by this build')
    return nil
  end

  local assigned = pcall(function() obj.dataBlock = dataBlock end)
  if not assigned then setObjField(obj, 'dataBlock', dataBlock) end
  setObjField(obj, 'numDrops', 0)
  setObjField(obj, 'boxWidth', 120)
  setObjField(obj, 'boxHeight', 80)
  setObjField(obj, 'dropSize', 0.07)
  setObjField(obj, 'splashSize', 0.16)
  setObjField(obj, 'splashMS', 80)
  setObjField(obj, 'fadeDist', 40)
  setObjField(obj, 'fadeDistEnd', 75)
  setObjField(obj, 'useTurbulence', 1)
  setObjField(obj, 'useWind', 1)

  local regOk = pcall(function() obj:registerObject(name) end)
  if not regOk then
    pcall(function() obj:delete() end)
    warnOnce('precip_reg', 'native rain skipped: could not register ' .. name)
    return nil
  end
  pcall(function() root:addObject(obj) end)
  return obj
end

local function clearManagedPrecip()
  deleteObject(PRECIP_HEAVY)
  deleteObject(PRECIP_FINE)
  precip.heavy, precip.fine = nil, nil
end

local function restoreExistingPrecip()
  if not precip.existing or not precip.orig then return end
  local obj = precip.existing
  setNumDrops(obj, precip.orig.numDrops or 0)
  for _, field in ipairs({ 'dropSize', 'splashSize', 'boxWidth', 'boxHeight', 'splashMS', 'position' }) do
    if precip.orig[field] ~= nil then setObjField(obj, field, precip.orig[field]) end
  end
  precip.orig = nil
end

-- 0.8: the game's own weather. Reads the rain particles of the level's Precipitation objects (not the mod's) and maps
-- them to a rain amount with 'Maximum rain particles' as full rain. Never writes to them.
local weather = { target = nil, objects = 0, drops = 0 }
local function readGameRain()
  local ok, list = pcall(function() return scenetree.findClassObjects('Precipitation') end)
  if not ok or type(list) ~= 'table' then return nil end
  local drops, n = 0, 0
  for _, name in ipairs(list) do
    if name ~= PRECIP_HEAVY and name ~= PRECIP_FINE then
      local o = scenetree.findObject(name)
      if o then
        local d = nil
        pcall(function() d = tonumber(o.numDrops) end)
        if d == nil then pcall(function() d = tonumber(o:getField('numDrops', 0)) end) end
        if d then drops, n = drops + d, n + 1 end
      end
    end
  end
  weather.objects, weather.drops = n, drops
  if n == 0 then return 0 end
  return clamp((drops / math.max(S.precipMaxDrops, 1)) ^ (1 / 1.2), 0, 1)
end

local function updatePrecipitation()
  if precip.existingName and not scenetree.findObject(precip.existingName) then
    precip.existing, precip.existingName, precip.orig = nil, nil, nil
  end
  if precip.heavy and not scenetree.findObject(PRECIP_HEAVY) then precip.heavy = nil end
  if precip.fine and not scenetree.findObject(PRECIP_FINE) then precip.fine = nil end

  local levelName = nil
  if type(getCurrentLevelIdentifier) == 'function' then
    local ok, name = pcall(getCurrentLevelIdentifier)
    if ok then levelName = name end
  end

  if S.followWeather then
    -- follow the game's weather: hand back any rain object we adjusted, then only read
    clearManagedPrecip()
    if precip.existing then restoreExistingPrecip() precip.existing = nil end
    weather.target = readGameRain()
    precip.count, precip.drops = weather.objects, weather.drops
    return
  end
  weather.target = nil

  if not S.enabled or not S.precipitation or S.rain <= 0.02 or levelName == nil then
    clearManagedPrecip()
    -- 0.8: give the level's own rain object its original state back (0.7 and older switched it off, which also
    -- killed rain started from the game's weather menu)
    if precip.existing then restoreExistingPrecip() precip.existing = nil end
    precip.count, precip.drops = 0, 0
    return
  end

  local existing, existingName = findExistingPrecip()
  if existing then
    rememberOrig(existing, existingName)
    precip.existing = existing
    clearManagedPrecip()
    local n = round(S.precipMaxDrops * (S.rain ^ 1.20))
    setNumDrops(existing, n)
    if S.precipFollow then
      setObjField(existing, 'position', fmt3(cam.x, cam.y, cam.z + 26.0))
    end
    precip.count, precip.drops = 1, n
    return
  end

  precip.existing = nil
  local useFine = S.rain >= 0.52
  if not precip.heavy then precip.heavy = createManagedPrecip(PRECIP_HEAVY, 'rain_medium') end
  if useFine and not precip.fine then precip.fine = createManagedPrecip(PRECIP_FINE, 'rain_drop') end
  if not useFine and precip.fine then deleteObject(PRECIP_FINE); precip.fine = nil end

  local heavyN = round(S.precipMaxDrops * 0.68 * (S.rain ^ 1.15))
  local fineN = 0
  if useFine then
    fineN = round(S.precipMaxDrops * 0.32 * math.max(0, (S.rain - 0.40) / 0.60))
  end

  local count = 0
  if precip.heavy then
    count = count + 1
    setNumDrops(precip.heavy, heavyN)
    setObjField(precip.heavy, 'boxWidth', 100 + 80 * S.rain)
    setObjField(precip.heavy, 'boxHeight', 60 + 55 * S.rain)
    setObjField(precip.heavy, 'dropSize', 0.05 + 0.07 * S.rain)
    setObjField(precip.heavy, 'splashSize', 0.12 + 0.16 * S.rain)
    if S.precipFollow then setObjField(precip.heavy, 'position', fmt3(cam.x, cam.y, cam.z + 24.0)) end
  end
  if precip.fine then
    count = count + 1
    setNumDrops(precip.fine, fineN)
    setObjField(precip.fine, 'boxWidth', 90 + 70 * S.rain)
    setObjField(precip.fine, 'boxHeight', 55 + 45 * S.rain)
    setObjField(precip.fine, 'dropSize', 0.04 + 0.04 * S.rain)
    if S.precipFollow then setObjField(precip.fine, 'position', fmt3(cam.x, cam.y, cam.z + 22.0)) end
  end
  precip.count = count
  precip.drops = heavyN + fineN
end

-- clouds (1.0) -------------------------------------------------------------------------------
-- While it rains the sky clouds over (more cover with more rain); when the rain stops, the mod is disabled or the
-- setting is switched off, the level's own cover comes back. If the player moves the cloud slider meanwhile, that
-- value becomes the new baseline. Only the documented core_environment cloud functions are used.
local clouds = { orig = nil, last = nil, level = nil }

local function restoreClouds()
  if clouds.orig ~= nil and core_environment and type(core_environment.setCloudCover) == 'function' then
    pcall(core_environment.setCloudCover, clouds.orig)
  end
  clouds.orig, clouds.last = nil, nil
end

local function updateClouds()
  local env = core_environment
  if not (env and type(env.getCloudCover) == 'function' and type(env.setCloudCover) == 'function') then return end
  local lvl = nil
  if type(getCurrentLevelIdentifier) == 'function' then pcall(function() lvl = getCurrentLevelIdentifier() end) end
  if lvl ~= clouds.level then clouds.level, clouds.orig, clouds.last = lvl, nil, nil end   -- new level: new baseline
  if lvl == nil then return end
  local rain = clamp(S.rain, 0, 1)
  if not (S.enabled and S.autoClouds and not S.followWeather and rain > 0.03) then
    restoreClouds()
    return
  end
  local okC, cur = pcall(env.getCloudCover)
  cur = okC and tonumber(cur) or nil
  if cur == nil then return end                                   -- no cloud layer on this level
  if clouds.orig == nil or (clouds.last and math.abs(cur - clouds.last) > 0.05) then clouds.orig = cur end
  local target = math.max(clouds.orig, 0.5 + 2.3 * (rain ^ 0.8))   -- light rain ~1.3 .. downpour ~2.8 (0 = clear)
  local new = cur + (target - cur) * 0.35                          -- eases in over a few seconds
  if math.abs(new - cur) > 0.01 then
    pcall(env.setCloudCover, new)
    clouds.last = new
  else
    clouds.last = cur
  end
end

-- look presets (1.0) ---------------------------------------------------------------------------
-- One click sets the rain and the whole wet look to a combination that fits together (players found the dozens of
-- sliders hard to balance: too dry, or a mirror road). The ground is wetted immediately, no wet-up wait.
local PRESETS = {
  damp    = { rain = 0.30, rainDropSize = 0.9, roadWetness = 0.75, roadRoughness = 0.58, roadReflection = 0.55, roadFlood = 0.00, roadNormal = 0.85,
              roadDarkening = 0.25, puddleCoverage = 0.20, puddleReflection = 0.45, puddleRoughness = 0.30, puddleRipple = 0.35 },
  wet     = { rain = 0.60, rainDropSize = 1.5, roadWetness = 0.90, roadRoughness = 0.40, roadReflection = 0.75, roadFlood = 0.20, roadNormal = 0.80,
              roadDarkening = 0.38, puddleCoverage = 0.36, puddleReflection = 0.68, puddleRoughness = 0.16, puddleRipple = 0.50 },
  storm   = { rain = 0.90, rainDropSize = 2.3, roadWetness = 1.00, roadRoughness = 0.34, roadReflection = 0.85, roadFlood = 0.40, roadNormal = 0.70,
              roadDarkening = 0.40, puddleCoverage = 0.48, puddleReflection = 0.74, puddleRoughness = 0.13, puddleRipple = 0.75 },
  flooded = { rain = 1.00, rainDropSize = 3.0, roadWetness = 1.00, roadRoughness = 0.28, roadReflection = 0.90, roadFlood = 0.80, roadNormal = 0.50,
              roadDarkening = 0.42, puddleCoverage = 0.64, puddleReflection = 0.80, puddleRoughness = 0.10, puddleRipple = 0.90 },
}

-- drop size (1.0) ------------------------------------------------------------------------------
-- 'Rain droplet size' (mm, the size of the falling raindrops). The beads on the cars and on the glass and the falling
-- rain all scale with it; 2.5 mm is the size the bead sliders were tuned at, so the default 1.5 mm makes every drop
-- smaller than before.
local function dropScale() return clamp((S.rainDropSize or 1.5) / 2.5, 0.15, 2.4) end

-- surroundings capture (1.0) -------------------------------------------------------------------
-- 'Dynamic reflections' for the wet road and the puddles. A reflection ray the screen-space trace cannot follow (it
-- leaves the screen, mostly upward) used to show a sky estimate, so puddles under trees, bridges and tunnel roofs
-- mirrored open sky. With fallback mode 3 the game renders one more small view of the real scene, looking straight up
-- from the camera (the engine's render-view feature, as the game's own split screen and rally clock use it), into a
-- named texture the puddle pass reads. World-aligned and square, so turning the camera never moves it. Everything is
-- optional: if the view cannot be made, or the mode is off, the earlier fallbacks are used and nothing is rendered.
local ENV = { name = 'rainPuddlesSurroundings', fov = 130, near = 0.3, proxy = 30 }
-- size, far distance and update rate (every n-th frame) follow the game's own 'Dynamic Reflections' quality
ENV.quality = { Disabled = { 256, 300, 4 }, Lowest = { 256, 300, 3 }, Low = { 320, 400, 3 }, Normal = { 384, 500, 2 },
                      High = { 512, 700, 2 }, Ultra = { 640, 900, 1 } }
local env = { rv = nil, ok = false, bound = false, ready = false, failed = false, px = 0, py = 0, pz = 0,
              r = { 1, 0, 0 }, u = { 0, 1, 0 }, f = { 0, 0, 1 }, tanH = math.tan(math.rad(ENV.fov * 0.5)), gain = 1.0,
              res = 384, far = 500, every = 2, quality = nil, q = nil, checkAt = -1e9 }

function env.wanted()
  return (S.enabled and ((S.roadFallback == 3 and S.wetGround) or (S.puddleFallback == 3 and S.puddles))
          and groundWetness() > 0.01) and true or false
end

function env.destroy()
  local rv = env.rv
  env.rv, env.ok = nil, false
  if rv then pcall(function() RenderViewManagerInstance:destroyView(rv) end) end
end

function env.create()
  local mgr = rawget(_G, 'RenderViewManagerInstance')
  if not mgr then error('this build has no RenderViewManagerInstance') end
  local quality = nil
  pcall(function() quality = settings.getValue('GraphicDynReflectionQuality') end)
  local qv = ENV.quality[tostring(quality)] or ENV.quality.Normal
  env.res, env.far, env.every, env.quality = qv[1], qv[2], qv[3], tostring(quality)
  local rv = mgr:getOrCreateView(ENV.name)
  if not rv then error('getOrCreateView returned nothing') end
  rv.luaOwned = true
  rv.namedTexTargetColor = ENV.name
  rv.resolution = Point2I(env.res, env.res)
  rv.viewPort = RectI(0, 0, env.res, env.res)
  -- cheap: no post effects (keeps this mod's own passes out of it too), no shadows, no cubemaps / mirrors, no editor
  -- overlays, lower mesh detail. Each is optional: a property this build lacks is skipped.
  local function opt(fn) pcall(fn) end
  opt(function() rv.usePostEffects = false end)
  opt(function() rv.renderShadows = false end)
  opt(function() rv.renderCubemap = false end)
  opt(function() rv.renderEditorIcons = false end)
  opt(function() rv.renderEditorGizmo = false end)
  opt(function()
    local s = RenderSettings.getGlobals()
    s.vehicleMirrorsEnabled = false
    s.vehicleDynamicReflectionsEnabled = false
    s.groundCoverScale = 0
    s.meshDetailAdjust = s.meshDetailAdjust * 0.6
    rv.settingsOverride = s
    rv.settingsOverrideEnabled = true
  end)
  -- looking straight up, image up = world +y. The same rotation gives the axes the shader projects with.
  local q = quatFromDir(vec3(0, 0, 1), vec3(0, 1, 0))
  local f = q * vec3(0, 1, 0)
  local u = q * vec3(0, 0, 1)
  local r = f:cross(u)
  env.q = q
  env.f = { norm3(f.x, f.y, f.z) }
  env.u = { norm3(u.x, u.y, u.z) }
  env.r = { norm3(r.x, r.y, r.z) }
  env.rv = rv
end

-- the puddle pass only gets the texture once the engine lists it (an unknown target name falls back to the back buffer)
function env.targetReady()
  if type(getAvailableNamedTexTargets) ~= 'function' then return env.ok end
  local ok, list = pcall(getAvailableNamedTexTargets, true)
  if not ok or type(list) ~= 'table' then return false end
  local pre = ENV.name .. '['                                     -- listed as 'name[RT0]' (0.40.5)
  for _, n in pairs(list) do
    n = tostring(n)
    if n == ENV.name or n == '#' .. ENV.name or n:sub(1, #pre) == pre then return true end
  end
  return false
end

function env.update()
  if not env.wanted() or env.failed then
    if env.rv then env.destroy() end
    return
  end
  if not env.rv then
    local ok, err = pcall(env.create)
    if not ok or not env.rv then
      env.failed = true
      env.destroy()
      log('W', TAG, 'surroundings capture not available, the reflections keep the sky fallback: ' .. tostring(err))
      return
    end
    log('I', TAG, string.format('surroundings capture on: %d x %d px, %d m, every %d. frame (game Dynamic Reflections: %s)',
      env.res, env.res, env.far, env.every, tostring(env.quality)))
  end
  -- from the camera; from inside a car from just above its roof (the cabin ceiling is not the surroundings)
  local x, y, z = cam.x, cam.y, cam.z
  for i = 1, #boxes do
    local b = boxes[i]
    if boxContains(b, x, y, z, 0.15) then
      z = math.max(z, b.cz + math.abs(b.a0[3]) * b.h[1] + math.abs(b.a1[3]) * b.h[2] + math.abs(b.a2[3]) * b.h[3] + 0.25)
    end
  end
  -- bounded cost: a new image every few frames, or right away after moving more than 4 m
  local due = (frameId % math.max(env.every, 1) == 0) or len3(x - env.px, y - env.py, z - env.pz) > 4
  if not due and env.ok then
    pcall(function() env.rv.active = false end)
    return
  end
  local q = env.q
  local ok, updated = pcall(function()
    return RenderViewManagerInstance:updateViewCamera(ENV.name, x, y, z, q.x, q.y, q.z, q.w, ENV.fov, ENV.near, env.far, false, 0)
  end)
  if not ok then
    env.failed = true
    env.destroy()
    log('W', TAG, 'surroundings capture switched off (camera update failed): ' .. tostring(updated))
    return
  end
  pcall(function() env.rv.active = (updated ~= false) end)
  -- same exposure as the main view, as the game does for its own extra views
  pcall(function()
    local main = RenderViewManagerInstance:getView('main')
    if main then env.rv.currentExposure = main.currentExposure end
  end)
  if updated ~= false then
    env.px, env.py, env.pz = x, y, z
    env.ok = true
  end
end

-- falling rain (1.0) ---------------------------------------------------------------------------
-- The mod's own rain, drawn on the GPU (rp_rain.cs.hlsl) instead of BeamNG's Precipitation particles, which simulate
-- every drop on the CPU (thousands of them in heavy rain) and cost a lot of frame time. Lua only integrates how far the
-- rain has fallen (wind + the fall speed of drops that size), the camera's own velocity (the streaks lean with it) and
-- a small grid of upward ray casts around the camera, so no rain falls under roofs, bridges and in tunnels.
-- (RAIN and rainSt are declared with the module state at the top)

function rainSt.castRoof(ix, iy, z0)
  if type(castRayStatic) ~= 'function' then return -1e5 end
  local ok, d = pcall(castRayStatic, vec3(ix * RAIN.spacing, iy * RAIN.spacing, z0), vec3(0, 0, 1), RAIN.reach)
  if ok and type(d) == 'number' and d > 0.01 and d < RAIN.reach - 0.01 then return z0 + d end
  return -1e5
end

function rainSt.update(dtSim)
  local rain = clamp(S.rain, 0, 1)
  rainSt.on = (S.enabled and S.rainStreaks and rain > 0.01) and true or false
  if not rainSt.on then rainSt.px = nil return end
  local dt = math.max(tonumber(dtSim) or 0, 0)
  -- the camera's own velocity: the streaks lean with it (the rain rushes at the windshield when driving)
  if rainSt.px then
    local dx, dy, dz = cam.x - rainSt.px, cam.y - rainSt.py, cam.z - rainSt.pz
    local jump2 = dx * dx + dy * dy + dz * dz
    -- a camera cut / teleport (also switching cameras: faster than 100 m/s) is no motion: otherwise the streaks point
    -- along the jump for a moment (seen in game: radial 'warp' streaks after a camera switch)
    if jump2 > 400 or (dt > 1e-4 and jump2 > (100 * dt) ^ 2) then
      rainSt.vx, rainSt.vy, rainSt.vz = 0, 0, 0
    elseif dt > 1e-4 then
      local k = 1 - math.exp(-dt / 0.08)
      rainSt.vx = rainSt.vx + (clamp(dx / dt, -90, 90) - rainSt.vx) * k
      rainSt.vy = rainSt.vy + (clamp(dy / dt, -90, 90) - rainSt.vy) * k
      rainSt.vz = rainSt.vz + (clamp(dz / dt, -90, 90) - rainSt.vz) * k
    end
  end
  rainSt.px, rainSt.py, rainSt.pz = cam.x, cam.y, cam.z
  if T - rainSt.windAt > 0.25 then
    rainSt.windAt = T
    local w = nil
    if be and be.getWindAt then pcall(function() w = be:getWindAt(vec3(cam.x, cam.y, cam.z)) end) end
    rainSt.wx, rainSt.wy = (w and tonumber(w.x)) or 0, (w and tonumber(w.y)) or 0
  end
  -- fall speed of drops this size (terminal velocity): 0.5 mm 2.1 m/s, 1.5 mm 5.4 m/s, 3 mm 8.0 m/s
  local D = clamp(S.rainDropSize or 1.5, 0.3, 6)
  local vt = math.max(9.65 - 10.3 * math.exp(-0.6 * D), 1.0)
  rainSt.vt = vt
  local P = RAIN.period
  rainSt.fx = (rainSt.fx + rainSt.wx * dt) % P
  rainSt.fy = (rainSt.fy + rainSt.wy * dt) % P
  rainSt.fz = (rainSt.fz - vt * dt) % P
  -- streak from a drop's head to its tail: its motion relative to the camera during a 1/60 s exposure
  local ex = clamp(S.rainStreakLength or 1, 0.1, 4) / 60
  local lx, ly, lz = (rainSt.vx - rainSt.wx) * ex, (rainSt.vy - rainSt.wy) * ex, (rainSt.vz + vt) * ex
  local l = len3(lx, ly, lz)
  if l > 1.1 then lx, ly, lz = lx * 1.1 / l, ly * 1.1 / l, lz * 1.1 / l end
  rainSt.lx, rainSt.ly, rainSt.lz = lx, ly, lz
end

-- 1.0 shelter grid: roof height over 9 x 9 upward casts 4 m apart (world-anchored) around the camera, a few casts per
-- frame (the inner 5 x 5 every 2 s, the outer ring every 4 s). Used by the falling rain (no drops under roofs), the
-- ground (dry and not reflective in tunnels, under bridges and roofs), the cars' drops and the wipers (no rain lands
-- there). Runs whenever the mod is on, also after the rain has stopped (the ground then stays wet outside only).
do
local ORDER = nil
local NAMES = {}
for q = 0, 20 do NAMES[q + 1] = '$rpShelter' .. q end
function rainSt.updateShelter()
  local n = RAIN.n
  local hn = (n - 1) / 2
  if not ORDER then
    ORDER = {}
    for j = -hn, hn do for i = -hn, hn do ORDER[#ORDER + 1] = { i, j, math.max(math.abs(i), math.abs(j)) } end end
    table.sort(ORDER, function(a, b) return a[3] < b[3] end)
  end
  local sp = RAIN.spacing
  local cx, cy = math.floor(cam.x / sp + 0.5), math.floor(cam.y / sp + 0.5)
  local budget, cache = 8, rainSt.cache
  for _, o in ipairs(ORDER) do
    if budget <= 0 then break end
    local key = (cx + o[1]) * 131071 + (cy + o[2])
    local e = cache[key]
    if not e or T - e.at > ((o[3] <= 2) and 2.0 or 4.0) or math.abs(cam.z - e.cz) > 3.0 then
      budget = budget - 1
      cache[key] = { z = rainSt.castRoof(cx + o[1], cy + o[2], cam.z + 0.3), at = T, cz = cam.z }
    end
  end
  local list, old = {}, rainSt.shelter
  local changed = (#old ~= n * n) or (cx * sp ~= rainSt.sox) or (cy * sp ~= rainSt.soy)
  local near = 0
  for j = -hn, hn do
    for i = -hn, hn do
      local e = cache[(cx + i) * 131071 + (cy + j)]
      local z = e and e.z or -1e5
      local idx = #list + 1
      list[idx] = z
      if old[idx] ~= z then changed = true end
      if z > -1e4 and math.abs(i) <= 3 and math.abs(j) <= 3 then near = near + 1 end
    end
  end
  rainSt.shelter, rainSt.sox, rainSt.soy = list, cx * sp, cy * sp
  if changed or not rainSt.shStr then
    local st = {}
    for q = 0, 20 do
      local k = q * 4
      st[q + 1] = fmt4(list[k + 1] or -1e5, list[k + 2] or -1e5, list[k + 3] or -1e5, list[k + 4] or -1e5)
    end
    rainSt.shStr = st
    rainSt.shG = fmt4(rainSt.sox, rainSt.soy, sp, 1)
  end
  -- a roof right above the camera, or roofs / a tunnel close by: the native wet-road film (it changes the road
  -- materials, i.e. everywhere at once) is switched off, so the mod draws the wet road itself and keeps the covered part
  -- dry. Held for 8 s, so passing under a few bridges does not flip it back and forth.
  rainSt.camCovered = (list[hn * n + hn + 1] or -1e5) > -1e4
  if rainSt.camCovered or near >= 2 then rainSt.dryNearUntil = T + 8 end
  rainSt.dryNear = T < rainSt.dryNearUntil
  if T - rainSt.pruneAt > 5 then
    rainSt.pruneAt = T
    for k, e in pairs(cache) do if T - e.at > 12 then cache[k] = nil end end
  end
end

-- the grid for a shader (rp_shelter_cb.h.hlsl); the strings are only rebuilt when a roof height changes
function rainSt.setConsts(fx)
  local st = rainSt.shStr
  if st and #rainSt.shelter == 81 then
    for q = 1, 21 do fx:setShaderConst(NAMES[q], st[q]) end
    fx:setShaderConst('$rpShelterG', rainSt.shG)
  else
    fx:setShaderConst('$rpShelterG', '0 0 4 0')
  end
end
end -- do (shelter grid)

-- roof height over a world point: the nearest sample (beyond the grid the nearest edge sample), -1e5 = open sky
function rainSt.roofAt(x, y)
  local sh = rainSt.shelter
  if #sh ~= 81 then return -1e5 end
  local sp = RAIN.spacing
  local i = clamp(math.floor((x - rainSt.sox) / sp + 4.5), 0, 8)
  local j = clamp(math.floor((y - rainSt.soy) / sp + 4.5), 0, 8)
  return sh[j * 9 + i + 1] or -1e5
end

-- 0..1 how covered a ground point is, as rpGroundCovered in the shaders (a roof at least 1.5 m above it)
function rainSt.coveredAt(x, y, z)
  local sh = rainSt.shelter
  if #sh ~= 81 then return 0 end
  local sp = RAIN.spacing
  local gx = clamp((x - rainSt.sox) / sp + 4, 0, 8)
  local gy = clamp((y - rainSt.soy) / sp + 4, 0, 8)
  local i0, j0 = math.min(math.floor(gx), 7), math.min(math.floor(gy), 7)
  local fx, fy = gx - i0, gy - j0
  fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
  local lim = z + 1.5
  local k00 = ((sh[j0 * 9 + i0 + 1] or -1e5) >= lim) and 1 or 0
  local k10 = ((sh[j0 * 9 + i0 + 2] or -1e5) >= lim) and 1 or 0
  local k01 = ((sh[(j0 + 1) * 9 + i0 + 1] or -1e5) >= lim) and 1 or 0
  local k11 = ((sh[(j0 + 1) * 9 + i0 + 2] or -1e5) >= lim) and 1 or 0
  local a = k00 + (k10 - k00) * fx
  local b = k01 + (k11 - k01) * fx
  return a + (b - a) * fy
end

-- 1.0 tunnels / roofs. Per car, how wet its body still is (its drops): under a roof no rain lands, so the drops go
-- slowly (about 2.5 min parked), faster the faster it drives (blown off: about 10 s at 110 km/h); back in the rain
-- they return within seconds. The player's car: when it went under a roof and came out again (sim time), for the
-- glass (no rain lands meanwhile) and the rain sensor (a couple more sweeps, then the wipers stop).
function rainSt.updateWet(dtSim)
  local dt = math.max(tonumber(dtSim) or 0, 0)
  local rain = clamp(S.rain, 0, 1)
  local vw = rainSt.vehWet
  for _, b in ipairs(boxes) do
    local e = vw[b.id]
    if not e then e = { w = 1 } vw[b.id] = e end
    e.at = T
    local cov = rainSt.coveredAt(b.cx, b.cy, b.cz - b.h[3])
    if dt > 0 then
      if cov > 0.5 then
        e.w = e.w * math.exp(-(1 / 150 + clamp((b.speed or 0) / 30, 0, 1.5) / 10) * dt)
      else
        e.w = e.w + (1 - e.w) * (1 - math.exp(-dt * (0.15 + 0.6 * rain)))
      end
    end
    b.wet, b.covered = e.w, cov
  end
  if T - rainSt.wetPruneAt > 10 then
    rainSt.wetPruneAt = T
    for id, e in pairs(vw) do if T - (e.at or 0) > 60 then vw[id] = nil end end
  end
  local ps, pb = rainSt.player, playerBox
  ps.cov = pb and (pb.covered or 0) or 0
  local want = ps.cov > 0.5
  if want ~= ps.on then
    ps.pend = ps.pend or TS
    if TS - ps.pend > 0.3 then
      ps.on, ps.pend = want, nil
      if want then
        ps.startTS, ps.endTS = TS, nil
        -- a couple more sweeps for the water still on the glass: two, three when driving fast
        ps.sweeps = ((pb and pb.speed or 0) > 16.7) and 3 or 2
        ps.wetHold = wiper.wet or 0
      else
        ps.endTS = TS
      end
    end
  else
    ps.pend = nil
  end
end

-- shader constants -------------------------------------------------------------------------

local EMPTY = '0 0 -100000 -1'
local NO_PROFILE = '-100 -100 -100 -100'

-- roof line of a droplet vehicle as 4 float4 (PROFILE_N = 16 heights), or the 'no profile' sentinel
local function setProfileConsts(fx, i, b)
  local p = b and profiles[b.id]
  local v = p and p.v
  local names = { '$rpVehPA', '$rpVehPB', '$rpVehPC', '$rpVehPD' }
  for q = 1, 4 do
    if v then
      local k = (q - 1) * 4
      fx:setShaderConst(names[q] .. i, fmt4(v[k + 1], v[k + 2], v[k + 3], v[k + 4]))
    else
      fx:setShaderConst(names[q] .. i, NO_PROFILE)
    end
  end
end

local function setVehConsts(fx, withMotion)
  local count = withMotion and MAX_VEH_DROPS or MAX_VEH_PUDDLES
  for i = 0, count - 1 do
    local b = boxes[i + 1]
    if withMotion then setProfileConsts(fx, i, b) end
    if b then
      fx:setShaderConst('$rpVehA' .. i, fmt4(b.cx, b.cy, b.cz, b.h[1]))
      fx:setShaderConst('$rpVehB' .. i, fmt4(b.a0[1], b.a0[2], b.a0[3], b.h[2]))
      fx:setShaderConst('$rpVehC' .. i, fmt4(b.a1[1], b.a1[2], b.a1[3], b.h[3]))
      fx:setShaderConst('$rpVehD' .. i, fmt4(b.a2[1], b.a2[2], b.a2[3], b.seed))
      -- z (1.0): 1 = the camera is inside this box (in-car views): the whole box is kept dry
      if not withMotion then fx:setShaderConst('$rpVehG' .. i, fmt4(b.gsx or 0, b.gsy or 0, b.inside and 1 or 0, b.gz or -100000)) end
      if withMotion then
        fx:setShaderConst('$rpVehE' .. i, fmt4(b.vx, b.vy, b.vz, b.wet or 1))   -- w (1.0): how wet the body still is
        fx:setShaderConst('$rpVehF' .. i, fmt4(b.wx, b.wy, b.wz, b.wake))
        fx:setShaderConst('$rpVehG' .. i, fmt4(b.ax or 0, b.ay or 0, b.az or 0, b.gz or -100000))
        -- z: no body droplets on the car whose cabin the camera is in (in-car views; the hood camera keeps them)
        fx:setShaderConst('$rpVehH' .. i, fmt4(b.flow or 0, b.sAir or 0, (b.inside and cam.cockpit) and 1 or 0, b.sGrav or 0))
      end
    else
      fx:setShaderConst('$rpVehA' .. i, EMPTY)
      fx:setShaderConst('$rpVehB' .. i, '1 0 0 0')
      fx:setShaderConst('$rpVehC' .. i, '0 1 0 0')
      fx:setShaderConst('$rpVehD' .. i, '0 0 1 0')
      if not withMotion then fx:setShaderConst('$rpVehG' .. i, '0 0 0 -100000') end
      if withMotion then
        fx:setShaderConst('$rpVehE' .. i, '0 0 0 0')
        fx:setShaderConst('$rpVehF' .. i, '0 0 0 0')
        fx:setShaderConst('$rpVehG' .. i, '0 0 0 0')
        fx:setShaderConst('$rpVehH' .. i, '0 0 0 0')
      end
    end
  end
end

local function setCommon(fx)
  if camFrame ~= frameId then updateCamera(); camFrame = frameId end
  -- 1.0: the camera position as it is RENDERED this frame. This extension's onPreRender can run before core_camera's
  -- own update, so the position read there was a frame old: everything anchored in the world (puddles, droplets on the
  -- cars) slid along with the camera whenever it moved. This callback runs while the frame is drawn.
  local x, y, z = callCamera('getPositionXYZ')
  if tonumber(x) and tonumber(y) and tonumber(z) then cam.x, cam.y, cam.z = x, y, z end
  fx:setShaderConst('$rpCam', fmt4(cam.x, cam.y, cam.z, T))
  fx:setShaderConst('$rpMode', fmt4(S.debugMode, S.depthMode, S.depthScale * (S.proceduralMasks and -1 or 1), S.debugBrightness))
end

-- roads only (0.8): nearest segments of the level's AI road network --------------------------------------------------
local ROAD_SEGS = 48                                   -- must match rp_puddles.h.hlsl
local roads = { at = -1e9, cx = 1e9, cy = 1e9, mode = 2, segs = {}, strA = {}, strB = {}, nodes = 0 }
local EMPTY_SEG = '0 0 -100000 0'

local function updateRoadSegments()
  roads.at, roads.cx, roads.cy = T, cam.x, cam.y
  roads.segs, roads.strA, roads.strB = {}, {}, {}
  local okM, m = pcall(function() return map and map.getMap and map.getMap() end)
  if not okM or type(m) ~= 'table' or type(m.nodes) ~= 'table' then roads.mode, roads.nodes = 2, 0 return end
  -- 1.0: every road link of the level once, bucketed in 64 m cells (rebuilt for a new level / map). The old code walked
  -- all nodes on every refresh (about 8,500 on West Coast USA: 1.5-5 ms, one to four times a second while driving).
  local lvl = nil
  pcall(function() lvl = getCurrentLevelIdentifier() end)
  local idx = roads.index
  if not idx or idx.map ~= m or idx.level ~= lvl or idx.nodes == 0 then
    idx = { map = m, level = lvl, nodes = 0, cells = {}, size = 64 }
    local size = idx.size
    for name, nd in pairs(m.nodes) do
      idx.nodes = idx.nodes + 1
      local p = type(nd) == 'table' and nd.pos
      local links = type(nd) == 'table' and (nd.links or (m.graph and m.graph[name]))
      if p and type(links) == 'table' then
        local sName = tostring(name)
        for other in pairs(links) do
          if sName < tostring(other) then                 -- every road link once
            local o = m.nodes[other]
            local q = type(o) == 'table' and o.pos
            if q then
              local seg = { p = p, q = q, ra = tonumber(nd.radius) or 4, rb = tonumber(o.radius) or 4 }
              for cx = math.floor(math.min(p.x, q.x) / size), math.floor(math.max(p.x, q.x) / size) do
                for cy = math.floor(math.min(p.y, q.y) / size), math.floor(math.max(p.y, q.y) / size) do
                  local key = cx * 100003 + cy
                  local c = idx.cells[key]
                  if not c then c = {} idx.cells[key] = c end
                  c[#c + 1] = seg
                end
              end
            end
          end
        end
      end
    end
    roads.index = idx
  end
  roads.nodes = idx.nodes
  if idx.nodes == 0 then roads.mode = 2 return end
  roads.mode = 1
  local R = math.max(S.maxDistance or 140, 40) + 15
  local size = idx.size
  local cand, seen = {}, {}
  for cx = math.floor((cam.x - R) / size), math.floor((cam.x + R) / size) do
    for cy = math.floor((cam.y - R) / size), math.floor((cam.y + R) / size) do
      local c = idx.cells[cx * 100003 + cy]
      if c then
        for _, seg in ipairs(c) do
          if not seen[seg] then
            seen[seg] = true
            -- distance from the camera to the segment (2D)
            local p, q = seg.p, seg.q
            local ex, ey = q.x - p.x, q.y - p.y
            local l2 = ex * ex + ey * ey
            local t = l2 > 1e-6 and clamp(((cam.x - p.x) * ex + (cam.y - p.y) * ey) / l2, 0, 1) or 0
            local sx, sy = p.x + ex * t - cam.x, p.y + ey * t - cam.y
            local d2 = sx * sx + sy * sy
            if d2 < R * R then cand[#cand + 1] = { d2 = d2, seg = seg } end
          end
        end
      end
    end
  end
  table.sort(cand, function(x, y) return x.d2 < y.d2 end)
  for i = 1, math.min(#cand, ROAD_SEGS) do
    local c = cand[i].seg
    roads.segs[i] = c
    roads.strA[i] = fmt4(c.p.x, c.p.y, c.p.z, c.ra)
    roads.strB[i] = fmt4(c.q.x, c.q.y, c.q.z, c.rb)
  end
end

local function puddleConsts(fx)
  setCommon(fx)
  setVehConsts(fx, false)
  local water = puddleWater()                                     -- puddles follow the standing water level
  local cov = S.puddleCoverage * (0.18 + 0.82 * (water ^ 0.72))
  local size = S.puddleSize * (0.92 + 0.16 * water)
  local depthMix = clamp(S.puddleRoughness * (1.10 - 0.20 * water), 0, 1)
  fx:setShaderConst('$rpPuddleA', fmt4(cov, S.puddleStrength, S.puddleReflection, S.tileSize))
  fx:setShaderConst('$rpPuddleB', fmt4(S.puddleSoftness, S.puddleRipple, S.maxDistance, S.surfaceFilter))
  fx:setShaderConst('$rpPuddleC', fmt4(depthMix, size, S.skyReflection, S.puddleNormal))
  fx:setShaderConst('$rpPuddleD', fmt4(S.reflectionBlur, S.ssrSteps, S.ssrThickness, groundWetness()))
  fx:setShaderConst('$rpPuddleE', fmt4(S.roadReflection, S.tireMarkGloss, S.vehicleMask and 1 or 0, tonumber(wetCall('nativeFilm', S)) or 0))
  -- 0.6: global wet road block, independent of the puddle constants above
  fx:setShaderConst('$rpPuddleF', fmt4(S.roadRoughness, S.roadDarkening, S.roadNormal, S.roadWetness))
  fx:setShaderConst('$rpPuddleG', fmt4(S.roadVariation, S.roadSkyReflection, S.roadReflectionBlur, S.roadSsrThickness))
  -- 1.0 fallback mode 3 (surroundings): the shader gets mode 0 as the base and the capture on top where it covers
  local envOn = env.ok and env.bound
  fx:setShaderConst('$rpPuddleH', fmt4(S.roadSsrSteps, (S.roadFallback == 3) and 0 or S.roadFallback,
    (S.puddleFallback == 3) and 0 or S.puddleFallback, 0))
  fx:setShaderConst('$rpPuddleN', fmt4((envOn and S.roadFallback == 3) and 1 or 0, (envOn and S.puddleFallback == 3) and 1 or 0, 1.5, 0))
  fx:setShaderConst('$rpEnvA', fmt4(env.px, env.py, env.pz, envOn and 1 or 0))
  fx:setShaderConst('$rpEnvB', fmt4(env.r[1], env.r[2], env.r[3], env.tanH))
  fx:setShaderConst('$rpEnvC', fmt4(env.u[1], env.u[2], env.u[3], env.gain))
  fx:setShaderConst('$rpEnvD', fmt4(env.f[1], env.f[2], env.f[3], ENV.proxy))
  fx:setShaderConst('$rpPuddleI', fmt4(S.wetGround and 1 or 0, S.puddles and 1 or 0, S.roadPatchSize, S.roadMaxDistance))
  fx:setShaderConst('$rpPuddleJ', fmt4(S.vehMaskHeight, 0, 0, 0))
  local roadsMode = S.puddleRoadsOnly and roads.mode or 0
  fx:setShaderConst('$rpPuddleK', fmt4(floodAmount(), clamp(S.rain, 0, 1), roadsMode, #roads.segs))
  fx:setShaderConst('$rpPuddleL', fmt4(S.lightStreaks, S.stochasticGloss and 1 or 0, frameId % 1024, 0))
  fx:setShaderConst('$rpPuddleM', fmt4(S.tyreWakes, #wheels, 0, 0))
  setTyreConsts(fx)
  rainSt.setConsts(fx)                                            -- 1.0: dry under roofs / in tunnels
  for i = 0, ROAD_SEGS - 1 do
    fx:setShaderConst('$rpRoadA' .. i, roads.strA[i + 1] or EMPTY_SEG)
    fx:setShaderConst('$rpRoadB' .. i, roads.strB[i + 1] or EMPTY_SEG)
  end
end

local function dropletConsts(fx)
  setCommon(fx)
  setVehConsts(fx, true)
  local rain = clamp(S.rain, 0, 1)
  local density = S.dropletDensity * (0.15 + 0.85 * rain)
  fx:setShaderConst('$rpDropA', fmt4(density, S.dropletSize * dropScale(), S.dropletRefraction, S.dropletSpeed))
  fx:setShaderConst('$rpDropB', fmt4(S.dropletShell, S.dropletSheen, S.dropletMaxDistance, rain))
  fx:setShaderConst('$rpDropC', fmt4(S.dropletSlide, S.dropletAero, 1.0, S.dropletInertia))
  fx:setShaderConst('$rpDropD', fmt4(S.dropletRunners, S.dropletTrails, 0, 0))
end

-- camera lens droplets ---------------------------------------------------------------------
-- The shader is stateless: droplets live on a log-polar grid around the screen centre that scrolls OUTWARD by
-- lens.flow. Radial outward motion is a pure translation in log-polar space, so every droplet slides away from
-- the centre, faster the further out it is, and is simply gone once it passes the screen edge (nothing piles up).
-- Lua integrates the scroll (flow) from a smoothed speed, so speed changes alter the sweep rate smoothly.
local lens = { flow = 0, speed = 0, rain = 0, cover = 0, covered = false, coverAt = -1e9, px = nil, py = nil, pz = nil, active = false }

local function lensSpeedSource(dt)
  if playerBox then return playerBox.speed or 0 end
  -- free / observer camera: use the camera's own motion
  local s = 0
  if lens.px and dt > 1e-4 then s = math.min(len3(cam.x - lens.px, cam.y - lens.py, cam.z - lens.pz) / dt, 80) end
  return s
end

local function updateLens(dtSim, dtReal)
  lens.active = (S.enabled and S.lens and (not cam.cockpit or S.lensInCockpit)) and true or false
  local dt = math.max(tonumber(dtSim) or 0, 0)
  local spd = lensSpeedSource(dt)
  lens.px, lens.py, lens.pz = cam.x, cam.y, cam.z

  -- Shelter: a roof / bridge / tunnel above the camera stops new rain from reaching the lens.
  if T - lens.coverAt > 0.25 then
    lens.coverAt = T
    lens.covered = false
    if lens.active and type(castRayStatic) == 'function' then
      local ok, d = pcall(castRayStatic, vec3(cam.x, cam.y, cam.z + 0.3), vec3(0, 0, 1), 40.0)
      lens.covered = ok and type(d) == 'number' and d > 0.01 and d < 39.5 or false
    end
  end

  local rdt = math.max(tonumber(dtReal) or 0, 0)
  if rdt > 0 then
    lens.cover = lens.cover + ((lens.covered and 1 or 0) - lens.cover) * (1 - math.exp(-rdt / 0.6))
  end
  if dt > 0 then
    lens.speed = lens.speed + (spd - lens.speed) * (1 - math.exp(-dt / 0.7))       -- smooth speed transitions
    local targetRain = (lens.active and clamp(S.rain, 0, 1) or 0) * (1 - lens.cover)
    lens.rain = lens.rain + (targetRain - lens.rain) * (1 - math.exp(-dt / 1.2))
    local sN = clamp(lens.speed / 35.0, 0, 1.6)
    local rate = 0.04 + S.lensSpeedResponse * 2.2 * (sN ^ 1.3)                       -- log-radius units per second
    lens.flow = lens.flow + rate * dt
  elseif not lens.active then
    lens.rain = 0
  end
end

local function lensConsts(fx)
  setCommon(fx)
  local sN = clamp(lens.speed / 35.0, 0, 1)
  local rainC = clamp(lens.rain, 0, 1) ^ 1.15                                           -- light rain stays subtle
  local density = clamp(S.lensDensity * rainC * (0.55 + 0.45 * sN), 0, 1)              -- more drops at speed
  local active = (lens.active and density > 0.001) and 1 or 0
  fx:setShaderConst('$rpLensA', fmt4(S.lensIntensity, density, S.lensSize, S.lensRefraction))
  fx:setShaderConst('$rpLensB', fmt4(S.lensClearCenter, sN, 1.0 + 2.2 * sN, clamp(lens.rain, 0, 1)))
  local fr, it = {}, {}
  local LENS_CELLS = { 28, 44, 70 }   -- angular cells per layer (big/rare, medium, small/many); must match rp_lens.cs.hlsl
  for l = 1, 3 do
    local shift = lens.flow / (2 * math.pi / LENS_CELLS[l])   -- cells scrolled so far (double precision here)
    local i = math.floor(shift)
    fr[l] = shift - i
    it[l] = i % 1048576                                       -- exact in a float; one reshuffle every ~2^20 cells
  end
  fx:setShaderConst('$rpLensC', fmt4(fr[1], fr[2], fr[3], cam.aspect))
  fx:setShaderConst('$rpLensD', fmt4(it[1], it[2], it[3], active))
end

local WIPER = { park = 0.06, range = 1.75 }   -- tandem blades: parked pointing right, sweep ~100 deg up to the left

-- Constants for one pane of glass (1.0: the windshield, and the rear / hatch glass through a second pass of the same
-- shader). W = the pane in world space (or nil = nothing to draw), flow = its drop physics, wip = its wiper timeline (nil:
-- this pane has no wipers, drops only turn over naturally).
local function glassConsts(fx, W, flow, wip)
  setCommon(fx)
  local rain = clamp(S.rain, 0, 1)
  local active = 0
  local cx, cy, cz = 0, 0, 0
  local nx, ny, nz = 0, 1, 0
  local rx, ry, rz = 1, 0, 0
  local ux, uy, uz = 0, 0, 1
  local halfW, halfH = 1, 0.6
  if W then
    active = 1
    cx, cy, cz = W.cx, W.cy, W.cz
    nx, ny, nz = W.nx, W.ny, W.nz
    rx, ry, rz = W.rx, W.ry, W.rz
    ux, uy, uz = W.ux, W.uy, W.uz
    halfW, halfH = W.halfW, W.halfH
  end

  -- times are sent relative to now (double precision here), so the shader never subtracts large absolute times
  local tc, sweepT, period, flags, cycles = 0, 1, 1, 0, 0
  if wip then
    tc = math.min(TS - wip.cycleStart, 1e5)
    sweepT, period, cycles = wip.sweepT, wip.period, wip.cycles
    flags = (wip.everWiped and 1 or 0) + (wip.repeating and 2 or 0)
      + ((wip.cycleStart - wip.period >= wip.runStart - 1e-3) and 4 or 0)
      + ((wip.ease == 1) and 8 or 0)                                  -- 1.0: Animated Wipers' cosine easing
  end
  -- 1.0 tunnels: when the car went under a roof and came out again (seconds ago, sim time; 0 = never / still under
  -- it): no rain lands in between. The drops that never get wiped go slowly with the car's wetness.
  local ps = rainSt.player
  local shA = ps.startTS and math.min(TS - ps.startTS, 1e5) or 0
  local shB = (ps.startTS and ps.endTS) and math.min(TS - ps.endTS, 1e5) or 0
  local wetP = playerBox and playerBox.wet or 1
  -- 1.0: which side of the pane the camera is on, from the geometry (normal points out of the car)
  local outside = W and ((cam.x - cx) * nx + (cam.y - cy) * ny + (cam.z - cz) * nz > 0) or false

  fx:setShaderConst('$rpWindA', fmt4(cx, cy, cz, halfW))
  fx:setShaderConst('$rpWindB', fmt4(nx, ny, nz, halfH))
  fx:setShaderConst('$rpWindC', fmt4(rx, ry, rz, S.windshieldDensity * (0.35 + 0.65 * rain) * wetP))
  fx:setShaderConst('$rpWindD', fmt4(ux, uy, uz, S.windshieldSize * dropScale()))
  fx:setShaderConst('$rpWindE', fmt4(tc, sweepT, period, flags))
  fx:setShaderConst('$rpWindF', fmt4(S.wiperTrail, 0, rain, S.dropletRefraction))   -- y: no drawn blades (1.0)
  fx:setShaderConst('$rpWindG', fmt4(flow.speed, active, cam.aspect, outside and 1 or 0))
  fx:setShaderConst('$rpWindH', fmt4(WIPER.park, WIPER.range, flow.clock, flow.rateHold or flow.rate))
  -- z: 0 estimated plane, 1 ray probe, 2 real outline (jbeam frame or the glass mesh) in rpWindJ / K / P (1.0)
  local quad = W and W.quad
  local source = (W and W.probed) and (quad and 2 or 1) or 0
  fx:setShaderConst('$rpWindI', fmt4(cycles, shA, source, (W and W.rhd) and 1 or 0))   -- y (1.0): under a roof since
  -- 1.0: the drops move like the body droplets (force, running-drop travel and speed, life clock; see updateGlassFlow)
  fx:setShaderConst('$rpWindN', fmt4(flow.fa, flow.fb, flow.life, shB))      -- w (1.0): out from under it since
  fx:setShaderConst('$rpWindO', fmt4(flow.ox, flow.oy, flow.vx, flow.vy))
  local windshield = W     -- (the code below reads the pane under this name)
  if quad then
    fx:setShaderConst('$rpWindJ', fmt4(quad[1], quad[2], quad[3], quad[4]))   -- bottom-left, bottom-right (glass uv)
    fx:setShaderConst('$rpWindK', fmt4(quad[5], quad[6], quad[7], quad[8]))   -- top-right, top-left
  else
    fx:setShaderConst('$rpWindJ', '-1 -1 1 -1')
    fx:setShaderConst('$rpWindK', '1 1 -1 1')
  end
  -- 1.0: the glass outline as a polygon of up to 12 frame nodes (glass uv, counter-clockwise) and its forward bulge
  local poly = windshield and windshield.poly
  local nPoly = poly and math.min(math.floor(#poly / 2), 12) or 0
  local curv = windshield and windshield.curv
  -- 1.0: this car's own wiper blades (pivot, parked angle, signed sweep, inner / outer radius, glass pc units)
  local blades = windshield and windshield.blades
  local nBlades = blades and math.min(#blades, 4) or 0
  if not wip then nBlades = -1 end                                   -- no wipers on this pane at all
  fx:setShaderConst('$rpWindL', fmt4(nPoly, nBlades, S.dropletRunners or 0.6, S.dropletTrails or 0.5))
  local rr, ph = {}, {}
  for i = 1, 4 do
    local bl = blades and blades[i]
    if bl and i <= nBlades then
      fx:setShaderConst('$rpWindQ' .. (i - 1), fmt4(bl[1], bl[2], bl[3], bl[4]))
      rr[#rr + 1], rr[#rr + 2] = bl[5], bl[6]
      ph[i] = tonumber(bl[7]) or 0
    else
      fx:setShaderConst('$rpWindQ' .. (i - 1), '0 -10 0 1')
      rr[#rr + 1], rr[#rr + 2] = 0, 0
      ph[i] = 0
    end
  end
  fx:setShaderConst('$rpWindS0', fmt4(rr[1], rr[2], rr[3], rr[4]))
  fx:setShaderConst('$rpWindS1', fmt4(rr[5], rr[6], rr[7], rr[8]))
  fx:setShaderConst('$rpWindT', fmt4(ph[1], ph[2], ph[3], ph[4]))    -- 1.0 wiper model: where each blade rests on its arc
  fx:setShaderConst('$rpWindM', curv and fmt4(curv[1], curv[2], curv[3], curv[4]) or '0 0 0 0')
  for i = 0, 5 do
    local k = i * 4
    if poly and i * 2 < nPoly then
      local x1, y1 = poly[k + 1], poly[k + 2]
      local x2, y2 = poly[k + 3] or x1, poly[k + 4] or y1
      fx:setShaderConst('$rpWindP' .. i, fmt4(x1, y1, x2, y2))
    else
      fx:setShaderConst('$rpWindP' .. i, '0 0 0 0')
    end
  end
end

local function windshieldConsts(fx) glassConsts(fx, windshield, windFlow, wiper) end
-- 1.0 rear / hatch glass; with the car's rear wiper when it has one (wiper model)
local function rearGlassConsts(fx) glassConsts(fx, rearGlass, rearFlow, (rearGlass and rearGlass.blades) and rearWiper or nil) end

local function splashConsts(fx)
  setCommon(fx)
  local water = puddleWater()
  local cov  = S.puddleCoverage * (0.18 + 0.82 * (water ^ 0.72))
  local size = S.puddleSize * (0.92 + 0.16 * water)             -- same puddle field as puddleConsts
  -- 0.9: tyres throw spray as long as the road is wet (groundWetness), more in puddles
  fx:setShaderConst('$rpSplashA', fmt4(S.splashIntensity, S.splashSize, S.splashSpeedMin, groundWetness()))
  fx:setShaderConst('$rpSplashB', fmt4(cov, S.puddleSoftness, S.tileSize, S.splashPuddle))
  fx:setShaderConst('$rpSplashC', fmt4(water, S.maxDistance, size, clamp(S.rain, 0, 1)))
  setTyreConsts(fx)
end

-- 1.0 falling rain (see updateRain)
local function rainConsts(fx)
  setCommon(fx)
  local rain = clamp(S.rain, 0, 1)
  -- 1.0: less than half as many drops as before (in-game feedback: too much rain, twice)
  local prob = rainSt.on and clamp(0.02 + 0.45 * rain ^ 1.15, 0, 1) or 0
  fx:setShaderConst('$rpRainA', fmt4(S.rainStreakIntensity, prob, clamp(S.rainDropSize or 1.5, 0.3, 6) * 0.001, RAIN.maxDist))
  fx:setShaderConst('$rpRainB', fmt4(rainSt.lx, rainSt.ly, rainSt.lz, 1.0))
  -- the camera in the falling rain's frame, from the camera as it is drawn (setCommon), wrapped to the grids' period
  local qx, qy, qz = cam.x - rainSt.fx, cam.y - rainSt.fy, cam.z - rainSt.fz
  local pN, pF = 1024 * RAIN.nearCell, 1024 * RAIN.farCell
  fx:setShaderConst('$rpRainC', fmt4(qx % pN, qy % pN, qz % pN, RAIN.nearCell))
  fx:setShaderConst('$rpRainD', fmt4(qx % pF, qy % pF, qz % pF, RAIN.farCell))
  -- no rain inside the player's car (cockpit views; the glass is not in the depth buffer)
  local b = playerBox
  if b then
    fx:setShaderConst('$rpRainF', fmt4(b.cx, b.cy, b.cz, 1))
    fx:setShaderConst('$rpRainG', fmt4(b.a0[1], b.a0[2], b.a0[3], b.h[1]))
    fx:setShaderConst('$rpRainH', fmt4(b.a1[1], b.a1[2], b.a1[3], b.h[2]))
    fx:setShaderConst('$rpRainI', fmt4(b.a2[1], b.a2[2], b.a2[3], b.h[3]))
  else
    fx:setShaderConst('$rpRainF', '0 0 -100000 0')
    fx:setShaderConst('$rpRainG', '1 0 0 0')
    fx:setShaderConst('$rpRainH', '0 1 0 0')
    fx:setShaderConst('$rpRainI', '0 0 1 0')
  end
  rainSt.setConsts(fx)
end

-- post effect objects ----------------------------------------------------------------------

local function maskPath(index)
  return maskDir .. (MASK_FILES[index] or MASK_FILES[1])
end

local function deleteObjects()
  local names = { FX_L, FX_S, FX_R, FX_W, FX_RAIN, FX_D, FX_P, BLOCK, SIDE.fxL, SIDE.fxR, SHADER_L, SHADER_S, SHADER_W, SHADER_RAIN, SHADER_D, SHADER_P }
  for _, n in ipairs(PROBES) do
    names[#names + 1] = 'RainPuddles_ProbeFx' .. n
    names[#names + 1] = 'RainPuddles_ProbeShader' .. n
  end
  for _, name in ipairs(names) do
    local o = scenetree.findObject(name)
    if o then pcall(function() o:delete() end) end
    rawset(_G, name .. 'Callbacks', nil)
  end
end

local function skipEffect(fxName, on)
  local fx = scenetree.findObject(fxName)
  if fx then
    pcall(function() fx:setField('skipDraw', 0, on and '1' or '0') end)
  end
end

local function applyEnabled()
  local wantP = S.enabled and (S.puddles or S.wetGround)
  local wantD = S.enabled and S.droplets
  local wantW = S.enabled and S.windshield and windshield ~= nil       -- 1.0: also outside (buildWindshield decides)
  local wantR = S.enabled and S.windshield and rearGlass ~= nil        -- 1.0: rear / hatch glass
  local wantSL = S.enabled and S.windshield and S.sideGlass and SIDE.L ~= nil   -- 1.0: side windows
  local wantSR = S.enabled and S.windshield and S.sideGlass and SIDE.R ~= nil
  local wantS = S.enabled and S.splashes
  local wantL = S.enabled and S.lens and (not cam.cockpit or S.lensInCockpit)
  local wantRain = S.enabled and S.rainStreaks and S.rain > 0.01                -- 1.0 own falling rain
  local key = tostring(wantP) .. tostring(wantD) .. tostring(wantW) .. tostring(wantS) .. tostring(wantL) .. tostring(wantR)
    .. tostring(wantRain) .. tostring(wantSL) .. tostring(wantSR)
  if enabledCache == key then return end
  enabledCache = key
  skipEffect(FX_L, not wantL)
  skipEffect(FX_RAIN, not wantRain)

  skipEffect(FX_P, not wantP)
  skipEffect(FX_D, not wantD)
  skipEffect(FX_W, not wantW)
  skipEffect(FX_R, not wantR)
  skipEffect(SIDE.fxL, not wantSL)
  skipEffect(SIDE.fxR, not wantSR)
  skipEffect(FX_S, not wantS)

  if not S.enabled then
    clearManagedPrecip()
    if precip.existing then restoreExistingPrecip() precip.existing = nil end
    precip.count, precip.drops = 0, 0
  end
end

local function createObjects()
  local shaderDefs = {
    { SHADER_P, 'rp_puddles.cs.hlsl', puddleConsts },
    { SHADER_D, 'rp_droplets.cs.hlsl', dropletConsts },
    { SHADER_W, 'rp_windshield.cs.hlsl', windshieldConsts },
    { SHADER_S, 'rp_splashes.cs.hlsl', splashConsts },
    { SHADER_L, 'rp_lens.cs.hlsl', lensConsts },
    { SHADER_RAIN, 'rp_rain.cs.hlsl', rainConsts },
  }
  for _, n in ipairs(PROBES) do
    shaderDefs[#shaderDefs + 1] = { 'RainPuddles_ProbeShader' .. n, 'rp_probe' .. n .. '.cs.hlsl', puddleConsts }
  end
  for _, def in ipairs(shaderDefs) do
    local shader = createObject('ShaderData')
    shader.DXComputShaderName = shaderDir .. def[2]
    shader.pixVersion = 5.0
    shader:registerObject(def[1])
  end

  local block = createObject('GFXStateBlockData')
  block.zDefined = true
  block.zEnable = false
  block.zWriteEnable = false
  block.samplersDefined = true
  local samplers = {
    'SamplerClampPoint', 'SamplerClampPoint', 'SamplerClampLinear',
    'SamplerClampLinear', 'SamplerClampLinear', 'SamplerClampLinear',
  }
  for slot, sampler in ipairs(samplers) do
    block:setField('samplerStates', slot - 1, sampler)
  end
  block:registerObject(BLOCK)

  -- 1.0 slot 5 of the puddle pass: the surroundings capture once the engine lists it, otherwise any valid texture (the
  -- shader does not read it then)
  local envBind = (env.ok and env.ready) and true or false
  env.bound = envBind
  local envTex = envBind and ('#' .. ENV.name) or maskPath(S.maskA)
  local effects = {
    { FX_P, SHADER_P, '100', { '#prepass[RT0]', '#prepass[Depth]', '$backBuffer', maskPath(S.maskA), maskPath(S.maskB), envTex } },
    { FX_D, SHADER_D, '99',  { '#prepass[RT0]', '#prepass[Depth]', '$backBuffer', maskPath(S.maskA), maskPath(S.maskB), dropAtlasPath } },
    -- 1.0 falling rain, after the upscaler at full resolution: before it, XeSS / DLSS / FSR averaged the thin moving
    -- streaks away over their history (they have no motion vectors), so at night they were invisible
    { FX_RAIN, SHADER_RAIN, '98.8', { '#prepass[RT0]', '#prepass[Depth]', '$backBuffer' }, 'UpscaleOverlay' },
    -- 1.0: depth on slot 1 (point sampler) like the passes above; on slots 3 / 4 (linear) it read as empty, so the
    -- windshield rain covered the dashboard and pillars and the spray was not hidden behind the bodywork
    { FX_W, SHADER_W, '98',  { '$backBuffer', '#prepass[Depth]', maskPath(S.maskA), maskPath(S.maskB), wiperMaskPath, dropAtlasPath } },
    -- 1.0: the rear / hatch glass, a second pass of the windshield shader with its own pane and drop physics
    { FX_R, SHADER_W, '98.5', { '$backBuffer', '#prepass[Depth]', maskPath(S.maskA), maskPath(S.maskB), wiperMaskPath, dropAtlasPath } },
    -- 1.0: the side windows, one more pass per side (no wipers)
    { SIDE.fxL, SHADER_W, '98.6', { '$backBuffer', '#prepass[Depth]', maskPath(S.maskA), maskPath(S.maskB), wiperMaskPath, dropAtlasPath } },
    { SIDE.fxR, SHADER_W, '98.7', { '$backBuffer', '#prepass[Depth]', maskPath(S.maskA), maskPath(S.maskB), wiperMaskPath, dropAtlasPath } },
    { FX_S, SHADER_S, '97',  { '$backBuffer', '#prepass[Depth]', maskPath(S.maskA), maskPath(S.maskB) } },
    -- last: the lens sits on top of everything (slot 2 = linear sampler for the droplet atlas)
    { FX_L, SHADER_L, '96',  { '$backBuffer', maskPath(S.maskA), dropAtlasPath } },
  }
  local constSetters = { [FX_P] = puddleConsts, [FX_D] = dropletConsts, [FX_W] = windshieldConsts, [FX_R] = rearGlassConsts,
                         [FX_S] = splashConsts, [FX_L] = lensConsts, [FX_RAIN] = rainConsts,
                         [SIDE.fxL] = function(fx) glassConsts(fx, SIDE.L, SIDE.flowL, nil) end,
                         [SIDE.fxR] = function(fx) glassConsts(fx, SIDE.R, SIDE.flowR, nil) end }
  for _, n in ipairs(PROBES) do
    local fxn = 'RainPuddles_ProbeFx' .. n
    effects[#effects + 1] = { fxn, 'RainPuddles_ProbeShader' .. n, tostring(90 - n),
      { '#prepass[RT0]', '#prepass[Depth]', '$backBuffer', maskPath(S.maskA), maskPath(S.maskB) } }
    constSetters[fxn] = puddleConsts
  end

  for _, e in ipairs(effects) do
    local fxName, shaderName, priority, textures, bin = e[1], e[2], e[3], e[4], e[5]
    local callbacks = {}
    callbacks.onEnabled = function() return true end
    callbacks.setShaderConsts = function()
      local fx = scenetree.findObject(fxName)
      if fx then
        local ok, err = pcall(constSetters[fxName], fx)
        if not ok then warnOnce('consts_' .. fxName, 'setting shader constants failed: ' .. tostring(err)) end
      end
    end
    rawset(_G, fxName .. 'Callbacks', callbacks)

    local fx = createObject('PostEffect')
    fx:setField('renderTime', 0, 'PFXBeforeBin')
    fx:setField('renderBin', 0, bin or 'UpscaleDispatch')
    fx:setField('renderPriority', 0, priority)
    fx:setField('shader', 0, shaderName)
    fx:setField('stateBlock', 0, BLOCK)
    for slot, texture in ipairs(textures) do
      fx:setField('texture', slot - 1, texture)
    end
    local targetSet = pcall(function() fx:setField('target', 0, '$backBuffer') end)
    if not targetSet then fx.target = '$backBuffer' end
    pcall(function() fx.allowReflectPass = false end)
    fx:registerObject(fxName)
    pcall(function() fx:enable() end)
  end
end

local function rebuild()
  deleteObjects()
  enabledCache = nil
  local ok, err = pcall(createObjects)
  if not ok then
    log('E', TAG, 'creating post effects failed: ' .. tostring(err))
    return false
  end
  applyEnabled()
  log('I', TAG, 'post effects created (puddles, droplets, rain, windshield, rear glass, splashes, lens)'
    .. (env.bound and '; puddle reflections read the surroundings capture' or ''))
  return true
end

-- wipers ------------------------------------------------------------------------------------

-- Wipers: eased out-and-back sweeps. 1.0 rain sensor: they switch on by themselves as soon as rain lands on the glass
-- and pick intermittent / normal / fast from how much water hits it (the rain, and more when driving into it), like a
-- car's automatic wipers. A new speed takes effect when the blades are parked (start of the next cycle), as on a real
-- wiper motor, so the clearing always follows the speed in use and never jumps. They keep running while you look from
-- outside, so the glass is in a believable state from every camera.
local function startWipeCycle()
  wiper.cycleStart = TS
  wiper.everWiped = true
  wiper.cycles = wiper.cycles + 1
end

-- 1.0: the player's wiper stalk, when the car reports one (see rainPuddlesProbe.reportWheels): [vid] = { v, at, used }
local wiperStalk = {}
-- 1.0: cars with a part driven by the "wipers" electrics value (a stalk prop, or a modded car's animated wipers):
-- [vid] = true / false; and the value the mod last wrote there, so its own echo is not taken for the player's hand
local wiperProp = {}
local wiperOut = {}

local WIPER_MODE_NAME = { [0] = 'off', 'intermittent', 'normal', 'fast' }
local WIPER_STALK_VALUE = { [0] = 0, 0.2, 0.5, 1.0 }

local function carHasWiperProp(vid)
  if wiperProp[vid] == nil then
    local has = false
    local vd = vehicleData(vid)
    if vd and type(vd.props) == 'table' then
      for _, p in pairs(vd.props) do
        if type(p) == 'table' and p.func == 'wipers' then has = true break end
      end
    end
    wiperProp[vid] = has
  end
  return wiperProp[vid]
end

-- Puts the car's own wiper switch where the mod's wipers are (only on cars that have one; on the Midsize the stalk
-- moves, other official stalks are fixed in place, modded cars may animate their wipers from it).
local function syncCarWiperSwitch(mode)
  local b = playerBox
  if not (b and b.veh) or not carHasWiperProp(b.id) then return end
  local v = WIPER_STALK_VALUE[mode] or 0
  local out = wiperOut[b.id]
  if out and out.v == v and T - out.at < 5 then return end
  wiperOut[b.id] = { v = v, at = T }
  pcall(function()
    b.veh:queueLuaCommand(string.format('if electrics and electrics.values then electrics.values.wipers = %.2f end', v))
  end)
end

-- 1.0 bridge to the "Animated Wipers" mod (vehicle side: lua/vehicle/extensions/rainPuddlesWiperBridge.lua). When the
-- player's car runs those animated blades, the glass clears exactly when they move, and the rain sensor switches them
-- (until the player switches them by hand). Without that mod on the car the bridge stays idle and Rain Puddles runs its
-- own wiper timeline. Only that mod's public controller / electrics are used; nothing of it is shipped here.
local awState = {}      -- [vid] = { present, at, start, period, sweepT, stalk, cmd, cmdAt, manual, loadedAt, newCycle }
local AW_SWEEP = { [0] = 1.43, 1.43, 1.43, 1.11 }   -- seconds per out + back before the first measured cycle

local function awFor(b)
  if not (b and b.veh) then return nil end
  local st = awState[b.id]
  if not st then
    st = { at = -1e9, cmdAt = -1e9, manual = false, loadedAt = -1e9 }
    awState[b.id] = st
  end
  local live = st.present and T - st.at < 2.0
  if not live and T - st.loadedAt > 10 then
    st.loadedAt = T
    pcall(function() b.veh:queueLuaCommand(string.format(
      "if not rainPuddlesWiperBridge then extensions.load('rainPuddlesWiperBridge') end if rainPuddlesWiperBridge then rainPuddlesWiperBridge.start(%d) end",
      b.id)) end)
  end
  return live and st or nil
end

-- 1.0 wiper model in the rain sensor. Wipes per minute the rain asks for: 8 in a drizzle, 32 where 'normal' takes over,
-- 48 in heavy rain, up to 80 in a downpour at speed (wet = rain on the glass, see updateWiper). A car whose blades clear
-- less of its glass (cov = the model's wiped share; 75 % is the reference) needs them more often for the same view.
local updateWiper
do
local function wipesNeeded(wet, cov)
  local need
  if wet <= 0.45 then need = 8 + 24 * clamp((wet - 0.04) / 0.41, 0, 1)
  elseif wet <= 1.05 then need = 32 + 16 * (wet - 0.45) / 0.60
  else need = 48 + 32 * clamp((wet - 1.05) / 1.45, 0, 1) end
  return need * clamp(0.75 / math.max(cov or 0.75, 0.3), 0.75, 1.6)
end

-- wipes per minute the Animated Wipers blades give in a mode: measured once that mode has run, typical values before
local AW_PERIOD = { 6.0, 3.0, 1.11 }
local function awSupply(aws, mode)
  local p = aws.per and aws.per[mode] or AW_PERIOD[mode] or 1.11
  return 60 / math.max(p, 0.3)
end

function updateWiper(dt)
  local k = math.max(S.wiperSpeed, 0.05)
  local lowT, highT = 1.5 / k, 1.0 / k                                -- seconds per out + back (normal / fast)
  -- rain sensor: water landing on the glass (1 = heavy rain while parked); driving into the rain adds up to 2.5x
  local wet = clamp(S.rain, 0, 1) * (1 + clamp((windFlow.speed or 0) / 20, 0, 1.5))
  -- 1.0 tunnels: no rain lands under a roof. The sensor keeps the water it saw before for a couple more sweeps (two,
  -- three when driving fast; counted in rainSt.updateWet), then the wipers stop until the car is back in the rain.
  local ps = rainSt.player
  if ps.on then wet = ps.wetHold or wet end
  -- 1.0 wiper model: the wipes per minute this rain needs on this car's glass against what each mode delivers
  -- (normal = 60 / lowT, fast = 60 / highT). With the reference coverage and the default wiper speed the switch points
  -- are the earlier ones (normal above 0.45, fast above 1.05, back below 0.35 / 0.90).
  local geoF = playerBox and wiperGeo[playerBox.id]
  local cov = geoF and geoF.model and geoF.model.coverage or 0.75
  local need = wipesNeeded(wet, cov)
  wiper.need, wiper.wet, wiper.coverage = need, wet, cov
  local supN = 60 / lowT
  local m = math.max(wiper.sensorMode or 0, 1)
  if m == 1 and need > supN * 0.667 then m = 2 elseif m == 2 and need < supN * 0.545 then m = 1 end   -- with hysteresis
  if m == 2 and need > supN then m = 3 elseif m == 3 and need < supN * 0.917 then m = 2 end
  wiper.sensorMode = m
  local auto = S.enabled and S.windshield and S.wiperAuto and S.rain > 0.04
  -- Animated Wipers on the player's car (bridge)? Its stalk value is then the bridge's business, not the player's hand.
  local aws = S.enabled and S.windshield and awFor(playerBox)
  -- a stalk the player has moved overrides the rain sensor: off / intermittent / normal / fast
  local stalk = playerBox and wiperStalk[playerBox.id]
  if not aws and stalk and stalk.used and T - (stalk.at or -1e9) < 1.5 and S.enabled and S.windshield then
    local v = stalk.v or 0
    auto = v > 0.05
    m = (v < 0.25) and 1 or ((v >= 0.75) and 3 or 2)
  end
  if not auto then m = 0 end

  if aws then
    -- 1.0 wiper model: those blades have their own three speeds, so the sensor picks the slowest one that still gives
    -- the wipes per minute the rain needs (one step up when it falls short, down when the slower one is enough again)
    if auto then
      local ma = clamp(aws.sensorMode or 1, 1, 3)
      while ma < 3 and need > awSupply(aws, ma) * 1.05 do ma = ma + 1 end
      while ma > 1 and need < awSupply(aws, ma - 1) * 0.85 do ma = ma - 1 end
      aws.sensorMode = ma
      m = ma
      if ps.on then
        if aws.newCycle and (ps.sweeps or 0) > 0 then ps.sweeps = ps.sweeps - 1 end
        if (ps.sweeps or 0) <= 0 then m = 0 end
      end
    end
    -- rain sensor -> the animated wipers' switch, unless the player has switched them by hand
    if S.wiperAuto and not aws.manual then
      if aws.cmd ~= m then
        aws.cmd, aws.cmdAt = m, T
        pcall(function() playerBox.veh:queueLuaCommand(string.format(
          'if rainPuddlesWiperBridge then rainPuddlesWiperBridge.setMode(%d) end', m)) end)
      elseif aws.stalk and T - aws.cmdAt > 2.5 and math.abs(aws.stalk - m / 3) > 0.15 then
        aws.manual = true          -- the stalk is not where the sensor put it: the player switched the wipers
      end
    end
    if aws.manual or not S.wiperAuto then m = math.floor((aws.stalk or 0) * 3 + 0.5) end
    -- the clearing follows the animated blades: a cycle starts when they leave the parked position
    if aws.newCycle then
      aws.newCycle = false
      if not wiper.running then wiper.running, wiper.runStart = true, aws.start end
      wiper.cycleStart = aws.start
      wiper.cycles = wiper.cycles + 1
      wiper.everWiped = true
    end
    wiper.sweepT = aws.sweepT or AW_SWEEP[m] or 1.43
    wiper.period = math.max(aws.period or (wiper.sweepT + 3.0), wiper.sweepT)
    wiper.repeating = true
    wiper.ease = 1                 -- cosine easing, as those blades move
    wiper.bridge = true
    wiper.mode = m
    wiper.active = (TS - wiper.cycleStart) < wiper.sweepT
    wiper.perMin = (m > 0 and aws.period) and (60 / aws.period) or 0
    return
  end
  wiper.ease, wiper.bridge = 0, false

  local sweepT = (m == 3) and highT or lowT
  -- intermittent: the pause shrinks as the rain gets heavier (6 s in a drizzle, under a second just before 'normal');
  -- 1.0: it is what is left of a minute after the wipes the rain needs on this car's glass
  local pause = (m == 1) and math.max(60 / math.max(need, 1) - sweepT, 0.3) or 0.0
  wiper.mode = m
  if auto then
    if not wiper.running then
      if ps.on and (ps.sweeps or 0) <= 0 then
        auto = false
      else
        if ps.on then ps.sweeps = ps.sweeps - 1 end
        wiper.running = true
        wiper.runStart = TS
        wiper.sweepT, wiper.period = sweepT, sweepT + pause
        startWipeCycle()
      end
    else
      -- finished cycles advance one at a time; each new cycle takes the speed and pause in use at its start
      local guard = 0
      while TS - wiper.cycleStart >= wiper.period and guard < 64 do
        if ps.on then
          if (ps.sweeps or 0) <= 0 then auto = false break end   -- 1.0 tunnel: no more sweeps
          ps.sweeps = ps.sweeps - 1
        end
        wiper.cycleStart = wiper.cycleStart + wiper.period
        wiper.cycles = wiper.cycles + 1
        wiper.sweepT, wiper.period = sweepT, sweepT + pause
        guard = guard + 1
      end
      if guard >= 64 then wiper.cycleStart = TS end
    end
  end
  if not auto then
    wiper.running = false            -- a sweep in progress still finishes (the shader parks the blade after sweepT)
  end
  wiper.repeating = auto and true or false
  wiper.active = (TS - wiper.cycleStart) < wiper.sweepT
  wiper.perMin = auto and (60 / math.max(wiper.period, 0.05)) or 0
  if S.enabled and S.windshield and S.wiperAuto then syncCarWiperSwitch(m) end
end
end -- do (rain sensor helpers)

-- 1.0 rear wiper. It runs while the windshield wipers do: intermittently on the mod's own timeline (about a third of
-- the wipes the windshield needs, at most every 2.5 s), or - with the Animated Wipers mod on the car - by switching that
-- mod's rear blade on in steady rain and clearing the glass on each of its measured sweeps. A rear blade the player
-- switches by hand is followed, never switched back.
local function updateRearWiper()
  local rw = rearWiper
  local has = rearGlass ~= nil and rearGlass.blades ~= nil
  local on = (has and S.enabled and S.windshield and S.rearWiper and S.wiperAuto and (wiper.mode or 0) > 0) and true or false
  local period = clamp(60 / math.max((wiper.need or 24) * 0.35, 1), 2.5, 12)
  local aws = playerBox and awState[playerBox.id]
  if aws and aws.present and T - aws.at < 2.0 and aws.rear then
    rw.ease, rw.bridge = 1, true
    if aws.newCycleR then
      aws.newCycleR = false
      if not rw.running then rw.running, rw.runStart = true, aws.startR end
      rw.cycleStart, rw.cycles, rw.everWiped = aws.startR, rw.cycles + 1, true
      -- sweeps we did not ask for: the player switched the rear wiper on
      if not aws.cmdR and T - (aws.cmdRAt or -1e9) > 3.0 then aws.manualR = true end
    end
    rw.sweepT = aws.sweepTR or 2.0
    rw.period = math.max(aws.periodR or rw.sweepT, rw.sweepT)
    rw.repeating = true
    local want = (on and (wiper.mode or 0) >= 2) and true or false
    if has and S.wiperAuto and not aws.manualR and (aws.cmdR or false) ~= want and T - (aws.cmdRAt or -1e9) > 1.0 then
      aws.cmdR, aws.cmdRAt = want, T
      pcall(function() playerBox.veh:queueLuaCommand(string.format(
        'if rainPuddlesWiperBridge and rainPuddlesWiperBridge.setRear then rainPuddlesWiperBridge.setRear(%d) end', want and 1 or 0)) end)
    end
    rw.perMin = (TS - rw.cycleStart < rw.period * 1.5) and (60 / math.max(rw.period, 0.05)) or 0
  else
    rw.ease, rw.bridge = 0, false
    local sweepT = 1.6 / math.max(S.wiperSpeed, 0.05)
    rw.repeating = on
    if on then
      if not rw.running then
        rw.running, rw.runStart = true, TS
        rw.sweepT, rw.period = sweepT, math.max(period, sweepT)
        rw.cycleStart, rw.everWiped, rw.cycles = TS, true, rw.cycles + 1
      else
        local guard = 0
        while TS - rw.cycleStart >= rw.period and guard < 64 do
          rw.cycleStart = rw.cycleStart + rw.period
          rw.cycles = rw.cycles + 1
          rw.sweepT, rw.period = sweepT, math.max(period, sweepT)
          guard = guard + 1
        end
        if guard >= 64 then rw.cycleStart = TS end
      end
    else
      rw.running = false
    end
    rw.perMin = on and (60 / math.max(rw.period, 0.05)) or 0
  end
  rw.active = (TS - rw.cycleStart) < rw.sweepT
end

-- Rain on the glass. The rain clock counts landed drops (faster in heavy rain and when driving into it). 1.0: the drops
-- move like the body droplets. The force along the glass (gravity, airflow, the car's acceleration) decides which beads
-- let go (they resist it with their adhesion, small ones longest); the running drops are blown up and across the glass
-- above ~45 km/h, run slowly down it when parked, are thrown forward when braking and sideways in corners. Their travel
-- is integrated here, so it has no limit and a change of speed never makes them jump. Frozen while paused.
-- One pane: flow = its state table, W = the pane (world), airK = how much of the airflow reaches it (the rear glass
-- sits in the car's wake), hitK = how much more rain hits it when driving (the windshield drives into the rain).
local function updateGlassFlow(flow, W, dt, airK, hitK)
  local b = playerBox
  local spd = b and b.speed or 0
  flow.speed = flow.speed + (spd - flow.speed) * (1 - math.exp(-dt / 0.6))
  local s = flow.speed
  local rate = (0.35 + 1.4 * clamp(S.rain, 0, 1) + clamp(s / 14, 0, 3) * hitK) * (S.rain > 0.01 and 1 or 0)
  -- 1.0: under a roof / in a tunnel no rain lands (the clock stops); the shader keeps the rate from before for the
  -- drops that had landed until then
  if rainSt.player.on then rate = 0 else flow.rateHold = rate end
  flow.rate = rate
  flow.clock = (flow.clock + rate * dt) % 8192
  local k = 1 - math.exp(-dt / 0.25)
  if not (b and W) then
    flow.fa, flow.fb = flow.fa * (1 - k), flow.fb * (1 - k)
    flow.vx, flow.vy = flow.vx * (1 - k), flow.vy * (1 - k)
    return
  end
  local windFlow = flow    -- (the code below works on this pane's state under this name)
  local aero, slide, inert = S.dropletAero or 1, S.dropletSlide or 0.8, S.dropletInertia or 1
  local st = accelState[b.id]
  local ax, ay, az = st and st.ax or 0, st and st.ay or 0, st and st.az or 0
  local rx, ry, rz = ((b.wx or 0) - b.vx) * airK, ((b.wy or 0) - b.vy) * airK, ((b.wz or 0) - b.vz) * airK   -- air
  local air = math.sqrt(rx * rx + ry * ry + rz * rz)
  -- force on a drop (m/s^2), the body droplets' model: gravity + quadratic air drag (stronger where the glass faces
  -- the wind) + the inertia of the car's acceleration
  local facing = clamp(-(rx * W.nx + ry * W.ny + rz * W.nz) / math.max(air, 1e-3), 0, 1)
  local kd = air * 0.018 * aero * (0.35 + 0.65 * facing)
  local Fx, Fy, Fz = rx * kd - ax * inert, ry * kd - ay * inert, rz * kd - 9.81 * slide - az * inert
  windFlow.fa = windFlow.fa + ((Fx * W.rx + Fy * W.ry + Fz * W.rz) - windFlow.fa) * k
  windFlow.fb = windFlow.fb + ((Fx * W.ux + Fy * W.uy + Fz * W.uz) - windFlow.fb) * k
  -- running drops (m/s along the glass): air sweeping along the glass, gravity, inertia
  local ta, tb = rx * W.rx + ry * W.ry + rz * W.rz, rx * W.ux + ry * W.uy + rz * W.uz
  local tl = math.sqrt(ta * ta + tb * tb)
  local va, vb = 0, 0
  if tl > 1e-3 then
    local vAir = math.max(tl - 11.0, 0) * 0.045 * aero
    va, vb = ta / tl * vAir, tb / tl * vAir
  end
  local ga, gb = -9.81 * W.rz, -9.81 * W.uz
  local gl = math.sqrt(ga * ga + gb * gb)
  if gl > 1e-3 then
    local vG = 0.05 * slide * gl / 9.81
    va, vb = va + ga / gl * vG, vb + gb / gl * vG
  end
  va = va - (ax * W.rx + ay * W.ry + az * W.rz) * 0.012 * inert
  vb = vb - (ax * W.ux + ay * W.uy + az * W.uz) * 0.012 * inert
  local hh = math.max(W.halfH or 0.5, 0.1)
  windFlow.vx = windFlow.vx + (va / hh - windFlow.vx) * k
  windFlow.vy = windFlow.vy + (vb / hh - windFlow.vy) * k
  -- travel in glass units, folded back by 512 with hysteresis (keeps float precision; a fold is a one-off reshuffle)
  local function fold(o) if o > 768 then return o - 512 elseif o < -768 then return o + 512 end return o end
  windFlow.ox = fold(windFlow.ox + windFlow.vx * dt)
  windFlow.oy = fold(windFlow.oy + windFlow.vy * dt)
  local airRate = math.min((air / 16.0) ^ 2, 6.0)
  windFlow.life = (windFlow.life + dt * (S.dropletSpeed or 1) * (1.0 + airRate)) % 16384.0
end

local function updateWindFlow(dtSim)
  local dt = math.max(tonumber(dtSim) or 0, 0)
  if dt <= 0 then return end
  updateGlassFlow(windFlow, windshield, dt, 1.0, 1.0)
  updateGlassFlow(rearFlow, rearGlass, dt, 0.3, 0.15)      -- 1.0: rear / hatch glass, in the car's wake
  updateGlassFlow(SIDE.flowL, SIDE.L, dt, 0.8, 0.2)         -- 1.0: side windows, the air runs along them
  updateGlassFlow(SIDE.flowR, SIDE.R, dt, 0.8, 0.2)
end

-- hooks ------------------------------------------------------------------------------------

local function onExtensionLoaded()
  if extensions and not extensions.rainPuddlesWet then pcall(extensions.load, 'rainPuddlesWet') end
  if extensions and not extensions.rainPuddlesHydro then pcall(extensions.load, 'rainPuddlesHydro') end   -- 1.0
  loadSettings()
  updateCamera()
  rebuild()
  pushSettings()
  log('I', TAG, 'v' .. VERSION .. ' loaded: rain=' .. tostring(S.rain) .. ', windshield=' .. tostring(S.windshield))
end

local function onExtensionUnloaded()
  pcall(env.destroy)
  restoreClouds()
  restoreAllWiperMeshes()
  wetCall('restoreAll')
  saveSettings()
  restoreExistingPrecip()
  clearManagedPrecip()
  deleteObjects()
end

local function onUpdate(dtReal, dtSim, dtRaw)
  local dt = dtReal or 0
  T = T + dt
  TS = TS + math.max(tonumber(dtSim) or 0, 0)
  saveTimer = saveTimer + dt
  updateWiper(dt)
  updateRearWiper()
  wetCall('update', dt, groundWetness(), S, floodAmount(), rainSt.dryNear)
  sinceCheck = sinceCheck + dt
  precipTimer = precipTimer + dt

  if saveDirty and saveTimer > 8 then
    saveTimer = 0
    saveSettings()
  end

  if sinceCheck > 2 then
    sinceCheck = 0
    if not scenetree.findObject(FX_P) then
      log('I', TAG, 'post effects missing (level change?); recreating')
      rebuild()
    end
  end

  if S.followWeather and weather.target then
    S.rain = S.rain + (weather.target - S.rain) * (1 - math.exp(-dt / 3.0))   -- weather changes fade in
  end

  if precipTimer > 0.75 then
    precipTimer = 0
    updateCamera()
    updatePrecipitation()
    pcall(updateClouds)
    applyEnabled()
  end
end

local function onPreRender(dtReal, dtSim)
  frameId = frameId + 1
  frameDtSim = tonumber(dtSim) or tonumber(dtReal) or 0
  updateCamera()
  camFrame = frameId
  if S.enabled and (S.puddles or S.wetGround or S.droplets or S.windshield or S.splashes or S.lens) then
    collectBoxes()
    buildWindshield()
    collectTyres(frameDtSim)
  else
    boxes, playerBox, playerVeh, wheels, windshield = {}, nil, nil, {}, nil
    cam.insideVehicle, cam.cockpit = false, false
  end
  -- 1.0 shelter grid (rain, dry ground in tunnels) and how wet each car still is
  if S.enabled then
    local okS, errS = pcall(rainSt.updateShelter)
    if not okS then warnOnce('shelter_update', 'shelter grid update failed: ' .. tostring(errS)) end
    local okW, errW = pcall(rainSt.updateWet, frameDtSim)
    if not okW then warnOnce('wet_update', 'car wetness update failed: ' .. tostring(errW)) end
  end
  updateLens(frameDtSim, dtReal)
  updateWindFlow(frameDtSim)
  updateWetness(frameDtSim)
  -- 1.0 own falling rain, and the surroundings capture for the reflection fallback (bound to the puddle pass once the
  -- engine lists its texture; rebuilt when that changes)
  local okRain, errRain = pcall(rainSt.update, frameDtSim)
  if not okRain then warnOnce('rain_update', 'falling rain update failed: ' .. tostring(errRain)) end
  local okEnv, errEnv = pcall(env.update)
  if not okEnv then warnOnce('env_update', 'surroundings capture update failed: ' .. tostring(errEnv)) end
  if env.ok ~= env.bound and T - env.checkAt > 0.5 then
    env.checkAt = T
    env.ready = env.ok and env.targetReady() or false
    if (env.ok and env.ready) ~= env.bound then rebuild() end
  end
  -- roads-only mask: refresh the nearest AI-road segments once a second or after moving 8 m
  if S.enabled and S.puddles and S.puddleRoadsOnly then
    local mx, my = cam.x - roads.cx, cam.y - roads.cy
    if T - roads.at > 1.0 or mx * mx + my * my > 64 then pcall(updateRoadSegments) end
  end
  applyEnabled()
end

-- public API --------------------------------------------------------------------------------

M.setSetting = function(key, value)
  if defaults[key] == nil then
    log('W', TAG, 'unknown setting: ' .. tostring(key))
    return
  end
  local def = defaults[key]
  if type(def) == 'number' then
    value = tonumber(value)
    if value == nil then return end
    value = clampSetting(key, value)
    if key == 'maskA' or key == 'maskB' or key == 'depthMode' or key == 'debugMode' or key == 'ssrSteps'
       or key == 'roadSsrSteps' or key == 'reflectionMode' or key == 'nativeSsrQuality'
       or key == 'roadFallback' or key == 'puddleFallback' then
      value = round(value)
    end
  elseif type(def) == 'boolean' then
    value = (value == true or value == 'true' or value == 1)
  else
    return
  end

  S[key] = value
  saveDirty = true

  if key == 'maskA' or key == 'maskB' then
    rebuild()
  elseif key == 'rain' or key == 'precipitation' or key == 'precipMaxDrops' then
    updateCamera()
    updatePrecipitation()
    applyEnabled()
  else
    applyEnabled()
  end
  pushSettings()
end

M.getSettings = function()
  return copyTable(S)
end

M.getSettingsJson = function()
  return jsonEncode(S)
end

-- 0.6.1 UI transport: the Vue UI cannot rely on the bridge knowing this extension, so it runs
-- 'extensions.rainPuddles.requestState()' as plain engine Lua. The state goes back both as the return value
-- (for transports with callbacks) and as the 'RainPuddlesState' UI event (for fire-and-forget transports).
M.requestState = function()
  local data = { settings = copyTable(S), diag = M.getDiagnostics() }
  uiTrigger('RainPuddlesState', data)
  return data
end

M.getDiagnostics = function()
  local ssr = false
  if PostFxSSSR and type(PostFxSSSR.isSupported) == 'function' then
    pcall(function() ssr = PostFxSSSR.isSupported() end)
  end
  return {
    vehicles = #boxes,
    cockpit = cam.cockpit and true or false,
    insideVehicle = cam.insideVehicle and true or false,
    camera = cam.name or '',
    precipitationObjects = precip.count,
    precipitationDrops = precip.drops,
    nativeSSR = ssr,
    wiperActive = wiper.active and true or false,
    wheels = #wheels,
    time = T,
    version = VERSION,
    wet = wetCall('getStatus'),
    hydro = (extensions.rainPuddlesHydro and extensions.rainPuddlesHydro.getStatus) and extensions.rainPuddlesHydro.getStatus() or nil,
    rayCast = (type(castRayStatic) == 'function'),
    nativeFilm = tonumber(wetCall('nativeFilm', S)) or 0,   -- 1 = the ground reflection is drawn by BeamNG's PBR + SSR
    groundWetness = groundWetness(),
    puddleWater = puddleWater(),
    flood = floodAmount(),
    roads = { mode = S.puddleRoadsOnly and roads.mode or 0, segments = #roads.segs, nodes = roads.nodes },
    weather = { following = S.followWeather and true or false, objects = weather.objects, drops = weather.drops },
    windshield = (function()
      local gmx = playerBox and glassMesh[playerBox.id]
      local pr = (gmx and gmx.front) or (playerBox and windProbe[playerBox.id])
      local geo = playerBox and wiperGeo[playerBox.id]
      if pr and pr.ok then
        return { source = pr.mesh and 'mesh' or (pr.frame and 'frame' or 'probe'), mesh = pr.mesh,
                 rear = gmx and gmx.rear and gmx.rear.mesh or nil,
                 hits = pr.hits, width = (pr.hw or 0) * 2, height = (pr.hh or 0) * 2,
                 roofProbe = pr.top, wipers = geo and geo.note or 'not measured yet', blades = geo and #geo.blades or 0,
                 wiperMode = WIPER_MODE_NAME[wiper.mode or 0] or 'off', wipesPerMin = math.floor((wiper.perMin or 0) + 0.5),
                 outside = S.windshieldOutside and true or false, animatedWipers = wiper.bridge and true or false,
                 -- 1.0 wiper model
                 coverage = geo and geo.model and geo.model.coverage or nil,
                 wipesNeeded = wiper.need and math.floor(wiper.need + 0.5) or nil,
                 rearWiper = (gmx and gmx.rear and wiperGeoR[playerBox.id]) and wiperGeoR[playerBox.id].note or nil,
                 rearWipesPerMin = math.floor((rearWiper.perMin or 0) + 0.5) }
      end
      return { source = 'estimate', note = pr and pr.note or (cam.cockpit and 'probing...' or 'sit in the car (in-car camera) to probe'),
               wiperMode = WIPER_MODE_NAME[wiper.mode or 0] or 'off', wipesPerMin = math.floor((wiper.perMin or 0) + 0.5) }
    end)(),
    lens = {
      active = lens.active,
      speed = lens.speed,
      rain = lens.rain,
      sheltered = lens.cover > 0.5,
    },
    -- 1.0 own falling rain and the surroundings capture
    rain = { own = rainSt.on, nativeParticles = S.precipitation and true or false, fallSpeed = rainSt.vt,
             dropSizeMm = S.rainDropSize, sheltered = rainSt.camCovered, groundDryNearby = rainSt.dryNear,
             carUnderRoof = rainSt.player.on, carWetness = playerBox and playerBox.wet or nil },
    surroundings = { on = (env.ok and env.bound) and true or false, wanted = env.wanted(), failed = env.failed,
                     size = env.res, far = env.far, every = env.every, gameQuality = env.quality },
    boxInfo = (function()
      local out = {}
      for i = 1, math.min(#boxes, 3) do
        local b = boxes[i]
        local lowZ = b.cz - (math.abs(b.a0[3]) * b.h[1] + math.abs(b.a1[3]) * b.h[2] + math.abs(b.a2[3]) * b.h[3])
        out[#out + 1] = string.format('#%d c.z %.2f half %.2f %.2f %.2f  bottom %.2f  plane %.2f (ray %s) slope %.3f %.3f  up.z %.2f %.2f %.2f',
          i, b.cz, b.h[1], b.h[2], b.h[3], lowZ, b.gz or -1, b.rayOff and string.format('%+.2f', b.rayOff) or 'none',
          b.gsx or 0, b.gsy or 0, b.a0[3], b.a1[3], b.a2[3])
      end
      return out
    end)(),
  }
end


-- Linux helper: scans beamng.log for shader/RainPuddles errors so nobody has to find the file.
-- Console (GE Lua):  extensions.rainPuddles.scanLog()
M.scanLog = function()
  local candidates = {}
  local okP, up = pcall(function() return FS:getUserPath() end)
  if okP and up then candidates[#candidates + 1] = up .. 'beamng.log' end
  candidates[#candidates + 1] = 'beamng.log'
  local text, usedPath
  for _, path in ipairs(candidates) do
    local ok, content = pcall(readFile, path)
    if ok and type(content) == 'string' and #content > 0 then text, usedPath = content, path break end
  end
  if not text then
    log('W', TAG, 'scanLog: could not read beamng.log (tried: ' .. table.concat(candidates, ', ') .. ')')
    return 'beamng.log not readable from Lua; use the grep command instead'
  end
  local hits = {}
  for line in text:gmatch('[^\r\n]+') do
    local l = line:lower()
    if l:find('rainpuddles', 1, true) or l:find('rp_', 1, true) or l:find('hlsl', 1, true)
       or l:find('error x', 1, true) or (l:find('shader', 1, true) and (l:find('error', 1, true) or l:find('fail', 1, true))) then
      hits[#hits + 1] = line
    end
  end
  local first = math.max(1, #hits - 60)
  local out = {}
  for i = first, #hits do out[#out + 1] = hits[i] end
  local report = 'RAINPUDDLES LOG SCAN (' .. usedPath .. '): ' .. #hits .. ' matching lines, showing last ' .. #out .. '\n' .. table.concat(out, '\n')
  pcall(writeFile, 'rainPuddles_logscan.txt', report)
  log('I', TAG, report)
  return report
end

-- One-command self test: extensions.rainPuddles.selfTest(13)
-- Sets the debug view, then reports what the shader/Lua side actually holds, and lists any shader compile errors
-- for the RainPuddles shaders found in beamng.log. Copy the console output back.
M.selfTest = function(mode)
  mode = tonumber(mode) or 13
  M.setSetting('debugMode', mode)
  local lines = {}
  lines[#lines + 1] = string.format('RainPuddles %s | enabled=%s puddles=%s | debugMode requested=%s stored=%s',
    VERSION, tostring(S.enabled), tostring(S.puddles), tostring(mode), tostring(S.debugMode))
  for _, name in ipairs({ FX_P, FX_D, FX_W, FX_S, FX_L, SHADER_P }) do
    local ok, obj = pcall(scenetree.findObject, name)
    lines[#lines + 1] = string.format('  object %-28s %s', name, (ok and obj) and 'present' or 'MISSING')
  end
  local w = wetCall('getStatus')
  if type(w) == 'table' then
    lines[#lines + 1] = string.format('  wet roads: %s | materials %s ok %s fail %s | native SSR supported=%s object=%s quality=%s',
      tostring(w.status), tostring(w.matCount), tostring(w.okCount), tostring(w.failCount),
      tostring(w.ssr and w.ssr.supported), tostring(w.ssr and w.ssr.objectPresent), tostring(w.ssr and w.ssr.quality))
    if w.lastError then lines[#lines + 1] = '  wet last error: ' .. tostring(w.lastError) end
  else
    lines[#lines + 1] = '  wet module: NOT LOADED'
  end
  local okP, up = pcall(function() return FS:getUserPath() end)
  local text
  for _, path in ipairs({ (okP and up or '') .. 'beamng.log', 'beamng.log' }) do
    local okR, content = pcall(readFile, path)
    if okR and type(content) == 'string' and #content > 0 then text = content break end
  end
  local ok = (text ~= nil)
  if ok then
    local errs, lastFail = {}, nil
    for line in text:gmatch('[^\r\n]+') do
      if line:find('compile() failed', 1, true) and line:find('rainPuddles', 1, true) then lastFail = line end
      if line:find('rainPuddles', 1, true) and line:find('error', 1, true) then errs[#errs + 1] = line end
    end
    lines[#lines + 1] = '  last compile failure: ' .. tostring(lastFail or 'none found')
    for i = math.max(1, #errs - 8), #errs do lines[#lines + 1] = '  ' .. errs[i] end
  else
    lines[#lines + 1] = '  beamng.log not readable from Lua'
  end
  local report = table.concat(lines, '\n')
  log('I', TAG, report)
  return report
end

-- Console: extensions.rainPuddles.getWipers(vid) - the wiper blades read from a car's wiper mesh (glass pc units:
-- pivot x / y, parked angle, signed sweep, inner / outer radius), plus which meshes they came from
M.getWipers = function(vid)
  vid = tonumber(vid) or (playerBox and playerBox.id)
  local g = vid and wiperGeo[vid]
  return g and { blades = g.blades, meshes = g.meshes, note = g.note } or nil
end

-- Console: extensions.rainPuddles.getWiperModel(vid) - the measured wiper model of a car (1.0): per pane (windshield,
-- rear) every blade's pivot, reach, parked angle, sweep, swept area and tip travel, the share of the glass that gets
-- wiped, the overlap, the zones no blade reaches, the timing of each mode with the tip speed; and the rain sensor.
M.getWiperModel = function(vid)
  vid = tonumber(vid) or (playerBox and playerBox.id)
  if not vid then return nil end
  local k = math.max(S.wiperSpeed, 0.05)
  local aws = awState[vid]
  local awOn = (aws and aws.present and T - (aws.at or -1e9) < 2.0) and true or false
  local vd = vehicleData(vid)
  local sm = tonumber(vd and type(vd.animatedWipers) == 'table' and vd.animatedWipers.speedMult) or 1
  local function finish(model, modes, cosine)
    if not model then return nil end
    local tip = 0
    for _, bl in ipairs(model.blades) do tip = math.max(tip, bl.tipArc) end
    for _, md in ipairs(modes) do
      md.tipSpeedAvg = tip / math.max(md.sweepTime * 0.5, 0.05)            -- m/s over one stroke
      md.tipSpeedPeak = md.tipSpeedAvg * (cosine and (math.pi / 2) or 1.5)
      md.glassClearedPerMin = model.coverage * md.wipesPerMin                -- whole-glass areas wiped per minute
    end
    local out = {}
    for kk, v in pairs(model) do out[kk] = v end
    out.modes = modes
    return out
  end
  local front, rear = {}, {}
  if awOn then
    for m = 1, 3 do
      local sweepT = 2 / (((m == 3) and 1.8 or 1.4) * sm)
      local measured = aws.per and aws.per[m]
      local period = measured or math.max(({ 6, 3, 0 })[m], sweepT)
      front[m] = { mode = WIPER_MODE_NAME[m], sweepTime = sweepT, period = period, wipesPerMin = 60 / period,
                   measured = measured ~= nil }
    end
    local pR = aws.periodR or 2
    rear[1] = { mode = 'on', sweepTime = aws.sweepTR or 2, period = pR, wipesPerMin = 60 / pR, measured = aws.periodR ~= nil }
  else
    local lowT, highT = 1.5 / k, 1.0 / k
    local pInt = math.max(60 / math.max(wiper.need or 24, 1) - lowT, 0.3) + lowT
    front[1] = { mode = 'intermittent', sweepTime = lowT, period = pInt, wipesPerMin = 60 / pInt, note = 'the pause follows the rain' }
    front[2] = { mode = 'normal', sweepTime = lowT, period = lowT, wipesPerMin = 60 / lowT }
    front[3] = { mode = 'fast', sweepTime = highT, period = highT, wipesPerMin = 60 / highT }
    rear[1] = { mode = 'intermittent', sweepTime = 1.6 / k, period = rearWiper.period,
                wipesPerMin = 60 / math.max(rearWiper.period, 0.05) }
  end
  local geo, geoR = wiperGeo[vid], wiperGeoR[vid]
  return {
    windshield = finish(geo and geo.model, front, awOn),
    rear = finish(geoR and geoR.model, rear, awOn and aws.rear),
    notes = { windshield = geo and geo.note or 'not measured yet (look at or sit in the car)',
              rear = geoR and geoR.note or 'not measured yet' },
    animatedWipers = awOn,
    sensor = { mode = WIPER_MODE_NAME[wiper.mode or 0] or 'off', rainOnGlass = wiper.wet, wipesNeededPerMin = wiper.need,
               coverage = wiper.coverage, wipesPerMin = wiper.perMin, rearWipesPerMin = rearWiper.perMin },
  }
end

-- a level ends: the surroundings view belongs to its scene
M.onClientEndMission = function() pcall(env.destroy) end

-- Console: extensions.rainPuddles.getRoofLine(vid) - the droplet roof line of a vehicle (16 heights, box frame)
M.getRoofLine = function(vid)
  vid = tonumber(vid) or (playerBox and playerBox.id)
  local p = vid and profiles[vid]
  return p and p.v or nil
end

M.save = saveSettings

M.reset = function()
  S = copyTable(defaults)
  saveDirty = true
  wiper.running = false
  enabledCache = nil
  rebuild()
  updateCamera()
  updatePrecipitation()
  applyEnabled()
  pushSettings()
  saveSettings()
end

M.sweep = function()
  -- one manual sweep (ignored while a sweep is already running); with Animated Wipers the real blades do it
  if wiper.bridge and playerBox and playerBox.veh then
    pcall(function() playerBox.veh:queueLuaCommand('if rainPuddlesWiperBridge then rainPuddlesWiperBridge.wipe() end') end)
  elseif TS - wiper.cycleStart >= wiper.sweepT then startWipeCycle() end
  pushSettings()
end

M.rebuild = rebuild
M.pushSettings = pushSettings

-- Called from vehicle Lua (rainPuddlesProbe.lua) with the windshield found on that vehicle.
M.onWindshieldProbe = function(vid, res)
  vid = tonumber(vid)
  if not vid or type(res) ~= 'table' then return end
  -- 1.0: the car is probed a few times until a strong result comes back; the result with the most glass hits wins
  local old = windProbe[vid]
  -- a result from the jbeam windshield frame is exact and always wins; ray-probe results compete on glass hits
  if old and old.ok and not res.frame and (old.frame or not res.ok or (res.hits or 0) <= (old.hits or 0)) then return end
  windProbe[vid] = res
  if res.ok then
    log('I', TAG, string.format('windshield found on vehicle %d: %d hits on %d triangles, %.2f x %.2f m%s',
      vid, res.hits or 0, res.tris or 0, (res.hw or 0) * 2, (res.hh or 0) * 2, res.top and '' or ' (roof probe missed)'))
  else
    log('W', TAG, 'windshield probe on vehicle ' .. vid .. ' failed: ' .. tostring(res.note) .. ' - using the estimated glass plane')
  end
end

-- Console / UI: extensions.rainPuddles.applyPreset('damp' | 'wet' | 'storm' | 'flooded')
M.applyPreset = function(name)
  local p = PRESETS[tostring(name or ''):lower()]
  if not p then
    log('W', TAG, 'unknown preset: ' .. tostring(name))
    return false
  end
  for k, v in pairs(p) do S[k] = clampSetting(k, v) end
  saveDirty = true
  wetSim.ground, wetSim.puddle = clamp(S.rain, 0, 1), clamp(S.rain, 0, 1)   -- show the look now, no wet-up wait
  updateCamera()
  updatePrecipitation()
  pcall(updateClouds)
  applyEnabled()
  pushSettings()
  return true
end

-- Console / UI: extensions.rainPuddles.snapWetness() - skip the wet-up / drying time (ground = current rain now)
M.snapWetness = function()
  wetSim.ground, wetSim.puddle = clamp(S.rain, 0, 1), clamp(S.rain, 0, 1)
  pushSettings()
end

-- Console / UI: extensions.rainPuddles.rescanWindshield()  (probes the player's car again next time you sit in it)
M.rescanWindshield = function()
  if playerBox then
    windProbe[playerBox.id], probeAsk[playerBox.id] = nil, nil
  else
    windProbe, probeAsk = {}, {}
  end
end

M.onVehicleSpawned = function(vid)
  if vid then windProbe[vid], probeAsk[vid] = nil, nil end   -- new car / new config: probe again
  if vid then wheelSpin[vid], spinAsk[vid] = nil, nil end
  if vid then profiles[vid] = nil end
  if vid then wiperGeo[vid], wiperHidden[vid], wiperGeoR[vid] = nil, nil, nil end
  if vid then wiperProp[vid], wiperOut[vid], wiperStalk[vid] = nil, nil, nil end
  if vid then awState[vid] = nil end                         -- Animated Wipers reloads the car: load the bridge again
  if vid then glassMesh[vid] = nil end                       -- new car / config: read its glass meshes again
end

-- Called from vehicle Lua (rainPuddlesWiperBridge.lua) when the car runs the "Animated Wipers" mod (1.0).
M.onAnimatedWipers = function(vid, kind, val)
  vid, val = tonumber(vid), tonumber(val) or 0
  if not vid then return end
  if val ~= val or math.abs(val) > 1e5 then val = 0 end          -- 1.0: never trust a garbage reading (see the bridge)
  local st = awState[vid] or { at = -1e9, cmdAt = -1e9, manual = false, loadedAt = T }
  awState[vid] = st
  st.present, st.at = true, T
  if kind == 'start' then
    local s = TS - math.min(val, 0.05) * 0.5
    if st.start and s - st.start > 0.3 then
      st.period = s - st.start
      -- 1.0 wiper model: the measured period of the mode in use (not across a change of mode)
      local mode = math.floor((st.stalk or 0) * 3 + 0.5)
      if mode >= 1 and mode <= 3 and st.period < 20 and T - (st.cmdAt or -1e9) > st.period + 0.5 then
        st.per = st.per or {}
        st.per[mode] = st.period
      end
    end
    st.start, st.newCycle = s, true
  elseif kind == 'end' then
    if val > 0.2 and val < 10 then st.sweepT = val end
  elseif kind == 'state' then
    st.stalk = clamp(val, 0, 1)
  elseif kind == 'rear' then
    st.rear = val > 0.5                                        -- that mod has a rear wiper on this car
  elseif kind == 'startR' then
    local s = TS - math.min(val, 0.05) * 0.5
    if st.startR and s - st.startR > 0.3 and s - st.startR < 20 then st.periodR = s - st.startR end
    st.startR, st.newCycleR = s, true
  elseif kind == 'endR' then
    if val > 0.2 and val < 10 then st.sweepTR = val end
  end
end
M.onVehicleResetted = function(vid)
  if vid then profiles[vid] = nil end                        -- repaired: new roof line
  -- 1.0: a reset stops the car at once, so the smoothed speeds go too (lens drops and glass drops used to keep streaking
  -- and ease to a halt after a reset at speed); the body drops' acceleration filter starts again from the new state
  if vid then accelState[vid] = nil end
  if vid and (not playerBox or playerBox.id == vid) then
    lens.speed = 0
    for _, f in ipairs({ windFlow, rearFlow, SIDE.flowL, SIDE.flowR }) do f.speed, f.fa, f.fb, f.vx, f.vy = 0, 0, 0, 0, 0 end
    rainSt.vx, rainSt.vy, rainSt.vz, rainSt.px = 0, 0, 0, nil
  end
end

-- Called from vehicle Lua (rainPuddlesProbe.reportWheels) with the tread speed of each wheel (m/s, by wheel index).
M.onWheelSpin = function(vid, spd)
  vid = tonumber(vid)
  if not vid or type(spd) ~= 'table' then return end
  spd.at = T
  wheelSpin[vid] = spd
end
M.onVehicleDestroyed = M.onVehicleSpawned

-- Called from vehicle Lua with the car's "wipers" electrics value (stalk), when something sets it (1.0).
-- > 0.05 on (below 0.25 intermittent, from 0.75 fast), about 0 off, <= -0.5 one sweep (mist).
M.onWiperStalk = function(vid, v)
  vid, v = tonumber(vid), tonumber(v)
  if not vid or not v then return end
  local s = wiperStalk[vid] or {}
  -- 1.0: the value the rain sensor itself put on the car's switch is not the player's hand
  local out = wiperOut[vid]
  local echo = out ~= nil and math.abs(v - out.v) < 0.02
  if math.abs(v) > 0.05 and not echo then s.used = true end
  if v <= -0.5 and (s.v or 0) > -0.5 then M.sweep() end
  s.v, s.at = v, T
  wiperStalk[vid] = s
end

-- Opens the full-screen Vue settings route (also reachable from the pause menu > Mods tab).
-- Console: extensions.rainPuddles.openUI()
M.openUI = function()
  local router = extensions and extensions.ui_router
  -- 1.0: the router API is navigate() (there is no push(), so this command always failed before)
  if router and type(router.navigate) == 'function' then
    local ok, err = pcall(router.navigate, 'menu.rainPuddles', nil)
    if not ok then log('W', TAG, 'openUI failed: ' .. tostring(err)) end
    return ok
  end
  log('W', TAG, 'openUI: ui_router not available; use the pause menu > Mods > Rain Puddles')
  return false
end

M.status = function()
  log('I', TAG, 'version ' .. VERSION)
  local ssr = 'no'
  if PostFxSSSR and type(PostFxSSSR.isSupported) == 'function' then
    local ok, v = pcall(PostFxSSSR.isSupported)
    if ok and v then ssr = 'yes' end
  end
  log('I', TAG, string.format(
    'v0.3 puddles=%s droplets=%s windshield=%s splashes=%s precip=%d objs/%d drops, vehicles=%d, cockpit=%s cam=%s, nativeSSR=%s, wheels=%d, time=%.1f',
    tostring(scenetree.findObject(FX_P) ~= nil), tostring(scenetree.findObject(FX_D) ~= nil),
    tostring(scenetree.findObject(FX_W) ~= nil), tostring(scenetree.findObject(FX_S) ~= nil),
    precip.count, precip.drops, #boxes, tostring(cam.cockpit), tostring(cam.name), ssr, #wheels, T))
  for i, b in ipairs(boxes) do
    log('I', TAG, string.format('  box %d id=%s centre %.1f %.1f %.1f half %.2f %.2f %.2f speed %.1f wake %.2f',
      i, tostring(b.id), b.cx, b.cy, b.cz, b.h[1], b.h[2], b.h[3], b.speed, b.wake))
    local lowZ = b.cz - (math.abs(b.a0[3]) * b.h[1] + math.abs(b.a1[3]) * b.h[2] + math.abs(b.a2[3]) * b.h[3])
    log('I', TAG, string.format('    axes a0=(%.2f %.2f %.2f) a1=(%.2f %.2f %.2f) a2=(%.2f %.2f %.2f)  boxBottom=%.2f  rayGround=%s',
      b.a0[1], b.a0[2], b.a0[3], b.a1[1], b.a1[2], b.a1[3], b.a2[1], b.a2[2], b.a2[3], lowZ, tostring(b.gz)))
  end
  log('I', TAG, string.format('  wiper active=%s running=%s cycles=%d, windshieldPlane=%s, cam=%s cockpit=%s',
    tostring(wiper.active), tostring(wiper.running), wiper.cycles, tostring(windshield ~= nil), tostring(cam.name), tostring(cam.cockpit)))
end

-- 1.0 hydroplaning: what the cars need from this side (rainPuddlesHydro.lua passes it on) --------------------------------
-- The water: a film on every wet hard surface (deeper in heavy rain and as the road floods) and the puddles, with the
-- same field the puddle shader draws (coverage, size, softness and tiling as in puddleConsts, the same two masks).
M.hydroEnv = function()
  local rain = clamp(S.rain, 0, 1)
  local ground, water, flood = groundWetness(), puddleWater(), floodAmount()
  local mode = S.enabled and clamp(round(tonumber(S.hydroplaning) or 0), 0, 3) or 0
  local size = S.puddleSize * (0.92 + 0.16 * water)
  local function field(i) return (MASK_FILES[i] or MASK_FILES[1]):gsub('%.data%.png$', '.field') end
  return {
    enabled = mode > 0, mode = mode, strength = S.hydroStrength or 1, tread = S.hydroTread or 7,
    traffic = S.hydroTraffic and true or false, debug = S.hydroDebug and true or false,
    puddles = (S.puddles and ground > 0) and true or false,
    roadsOnly = (S.puddleRoadsOnly and roads.mode == 1) and true or false,
    tile = math.max(S.tileSize or 44, 2), cov = clamp(S.puddleCoverage * (0.18 + 0.82 * (water ^ 0.72)), 0, 1),
    sizeWarp = 0.58 + 0.76 * clamp(size, 0, 1), soft = math.max(S.puddleSoftness or 0.035, 0.004),
    fieldA = field(S.maskA), fieldB = field(S.maskB),
    -- metres: film 0.15 mm (damp) .. 1.2 mm (downpour) + up to 2 mm as the road floods; puddles up to 9 mm deep at
    -- their centre (a deep rut), half as deep again on a flooding road (tested: 15 mm made every puddle a spin at 100 km/h)
    hFilm = ground * (0.00015 + 0.00105 * rain ^ 0.8) + 0.002 * flood * ground,
    hPuddle = (S.puddles and 1 or 0) * (0.003 + 0.006 * water) * (1 + 0.5 * flood),
  }
end

-- the nearest road lanes to a point: { {ax, ay, az, ra, bx, by, bz, rb}, ... } (as the puddle shader's segments)
M.hydroRoads = function(x, y, z, n)
  local idx = roads.index
  if not idx then pcall(updateRoadSegments) idx = roads.index end
  if not idx then return nil end
  local size, R = idx.size, 12
  local cand, seen = {}, {}
  for cx = math.floor((x - R) / size), math.floor((x + R) / size) do
    for cy = math.floor((y - R) / size), math.floor((y + R) / size) do
      local c = idx.cells[cx * 100003 + cy]
      if c then
        for _, seg in ipairs(c) do
          if not seen[seg] then
            seen[seg] = true
            local pp, qq = seg.p, seg.q
            local ex, ey = qq.x - pp.x, qq.y - pp.y
            local l2 = ex * ex + ey * ey
            local t = l2 > 1e-6 and clamp(((x - pp.x) * ex + (y - pp.y) * ey) / l2, 0, 1) or 0
            local sx, sy = pp.x + ex * t - x, pp.y + ey * t - y
            local d2 = sx * sx + sy * sy
            local zS = pp.z + (qq.z - pp.z) * t
            if d2 < R * R and math.abs(zS - z) < 3 then cand[#cand + 1] = { d2 = d2, seg = seg } end
          end
        end
      end
    end
  end
  table.sort(cand, function(a, b) return a.d2 < b.d2 end)
  local out = {}
  for i = 1, math.min(#cand, n or 3) do
    local g = cand[i].seg
    out[i] = { g.p.x, g.p.y, g.p.z, g.ra, g.q.x, g.q.y, g.q.z, g.rb }
  end
  return out
end

-- 0..1 how covered (roof, bridge, tunnel) the ground at a point is: the shelter grid near the camera, an upward cast
-- (cached a second per car) further away
do
local castCache = {}
M.hydroCovered = function(x, y, z, vid)
  local sp = RAIN.spacing
  local dx, dy = x - rainSt.sox, y - rainSt.soy
  if #rainSt.shelter == 81 and math.abs(dx) < 4 * sp and math.abs(dy) < 4 * sp then return rainSt.coveredAt(x, y, z) end
  local key = (vid or 0) * 4096 + math.floor(x / 4) % 64 * 64 + math.floor(y / 4) % 64
  local e = castCache[key]
  if e and T - e.at < 1.0 then return e.c end
  local c = 0
  if type(castRayStatic) == 'function' then
    local ok, d = pcall(castRayStatic, vec3(x, y, z + 1.0), vec3(0, 0, 1), 40)
    if ok and type(d) == 'number' and d > 0.5 and d < 39.5 then c = 1 end
  end
  castCache[key] = { c = c, at = T }
  if T - (castCache.prunedAt or 0) > 10 then
    castCache.prunedAt = T
    for k, v in pairs(castCache) do if type(v) == 'table' and T - v.at > 5 then castCache[k] = nil end end
  end
  return c
end
end -- do (hydroplaning helpers)

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate
M.onPreRender = onPreRender

return M

