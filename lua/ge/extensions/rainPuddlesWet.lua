-- rainPuddlesWet.lua
-- Chains RainPuddles into BeamNG's own reflection pipeline instead of competing with it.
--
-- Documentation basis (documentation.beamng.com):
--   * Reflections: Screen Space Reflections (PostFxSSSRObject) trace after lighting, follow MATERIAL ROUGHNESS
--     (smooth surfaces such as wet roads receive traced reflections, rough ones keep the cubemap), blend over the
--     cubemap, need Lighting Quality High/Ultra and Direct3D 12 or Vulkan, and are Off in every preset.
--   * Post Process Effects: graphics keys PostFXSSRQuality (Off/Low/Medium/High) and PostFXSSRAvailable.
--   * Materials v1.5 / *.materials.json: roughnessFactor is a per-layer (Stages) scalar.
--
-- What this extension does:
--   1. WET ROAD PBR: while it rains, the roughnessFactor of the level's road materials (DecalRoad.material,
--      MeshRoad.topMaterial) is scaled toward cfg.roadRoughness (fraction of the dry value, 0.6), so the engine itself shades wet asphalt as glossy and feeds it to
--      native SSR + cubemap reflections. The original values are snapshotted and restored when the rain stops,
--      the setting is switched off, the level changes or the extension unloads.
--   2. NATIVE SSR CONTROL: optionally raises PostFXSSRQuality while it rains and restores the player's value.
--
-- Every engine call is guarded with pcall: if an API differs on some build the extension reports it through
-- getStatus() (shown in the app) and does nothing harmful.

local M = {}
local TAG = 'rainPuddlesWet'

local SSR_QUALITY = { [1] = 'Low', [2] = 'Medium', [3] = 'High' }
local MAX_LAYERS = 4
local APPLY_INTERVAL = 2.0      -- s between material rewrites (1.0: was 1 s; reload is not free)
local APPLY_STEP = 0.05         -- minimum change of the roughness multiplier that triggers a rewrite
local APPLY_BUDGET_MS = 1.0     -- 1.0: rewrite time per frame (at least one material per frame)
local SSR_INTERVAL = 1.0

local st = {
  clock = 0,
  wet = 0,                -- smoothed wetness 0..1
  appliedWet = -1,        -- wetness the materials currently reflect (-1 = never touched)
  appliedMult = 1,        -- roughness multiplier the materials currently carry (1 = original)
  lastApply = -1e9,
  lastScan = -1e9,
  lastSsr = -1e9,
  level = nil,
  mats = {},              -- name -> { layers = { [layer] = originalRoughnessFactor } }
  matCount = 0,
  okCount = 0,
  failCount = 0,
  status = 'idle',
  lastErr = nil,
  ssrPrev = nil,          -- player's PostFXSSRQuality before we changed it
}

local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

-- ---------------------------------------------------------------------------------------------------------------
-- graphics settings bridge (documented keys: PostFXSSRQuality, PostFXSSRAvailable)
-- ---------------------------------------------------------------------------------------------------------------
local function settingsApi()
  local api = rawget(_G, 'core_settings_settings')
  if not api and extensions then api = extensions.core_settings_settings end
  return api
end

local function getSetting(key)
  local api = settingsApi()
  if not api or type(api.getValue) ~= 'function' then return nil end
  local ok, v = pcall(api.getValue, key)
  if ok then return v end
  return nil
end

local function setSetting(key, value)
  local api = settingsApi()
  if not api or type(api.setValue) ~= 'function' then st.lastErr = 'settings API unavailable'; return false end
  local ok, err = pcall(api.setValue, key, value)
  if not ok then st.lastErr = tostring(err) end
  return ok
end

local function ssrSupported()
  local sup = false
  if PostFxSSSR and type(PostFxSSSR.isSupported) == 'function' then
    local ok, v = pcall(PostFxSSSR.isSupported)
    sup = ok and v and true or false
  end
  return sup
end

-- ---------------------------------------------------------------------------------------------------------------
-- road material discovery + snapshot
-- ---------------------------------------------------------------------------------------------------------------
local function readField(obj, field)
  local ok, v = pcall(function() return obj:getField(field, 0) end)
  if ok and type(v) == 'string' and v ~= '' then return v end
  local ok2, v2 = pcall(function() return obj[field] end)
  if ok2 and type(v2) == 'string' and v2 ~= '' then return v2 end
  return nil
end

local function discoverRoadMaterials()
  local names = {}
  local specs = { { 'DecalRoad', 'material' }, { 'MeshRoad', 'topMaterial' }, { 'MeshRoad', 'material' } }
  for _, spec in ipairs(specs) do
    local okList, list = pcall(scenetree.findClassObjects, spec[1])
    if okList and type(list) == 'table' then
      for _, objName in ipairs(list) do
        local obj = scenetree.findObject(objName)
        if obj then
          local mat = readField(obj, spec[2])
          if mat then names[mat] = true end
        end
      end
    end
  end
  return names
end

local function snapshotMaterial(name)
  local m = scenetree.findObject(name)
  if not m then return nil end
  local layers = 1
  local okA, a = pcall(function() return tonumber(m:getField('activeLayers', 0)) end)
  if okA and a and a >= 1 then layers = math.min(MAX_LAYERS, math.floor(a)) end
  local rec = { layers = {} }
  for l = 0, layers - 1 do
    local okR, v = pcall(function() return m:getField('roughnessFactor', l) end)
    local num = okR and tonumber(v) or nil
    rec.layers[l] = num or 1.0     -- unset factor = engine default of 1 (the roughness map, if any, then supplies the value)
  end
  return rec
end

local function rescan()
  st.lastScan = st.clock
  st.mats, st.matCount = {}, 0
  for name in pairs(discoverRoadMaterials()) do
    local rec = snapshotMaterial(name)
    if rec then
      st.mats[name] = rec
      st.matCount = st.matCount + 1
    end
  end
  if st.matCount == 0 then st.status = 'no road materials found on this level' end
end

-- One material: its layers' roughnessFactor scaled by mult (mult = 1 restores the exact original values), then reloaded.
-- 1.0: a reload costs about 3.5 ms per material (measured on West Coast USA: all 59 road materials at once blocked the
-- game for 205-225 ms each time, which was the stutter), so rewrites are spread over frames (st.job).
local function rewriteMaterial(name, rec, mult)
  local m = scenetree.findObject(name)
  if not (m and rec) then return false end
  local touched = false
  for l, orig in pairs(rec.layers) do
    local v = orig
    if mult < 0.999 then v = math.min(orig, math.max(orig * mult, 0.03)) end   -- never raises a value
    local okS, err = pcall(function() m:setField('roughnessFactor', l, string.format('%.4f', v)) end)
    if okS then touched = true else st.lastErr = tostring(err) end
  end
  if not touched then return false end
  local okR, errR = pcall(function() m:reload() end)
  if not okR then okR, errR = pcall(function() m:flush() end) end
  if not okR then st.lastErr = tostring(errR) end
  return okR
end

-- all at once: only to put the originals back (level change, mode switched, unloading)
local function applyRoughnessMultiplier(mult)
  st.job = nil
  local ok, bad = 0, 0
  for name, rec in pairs(st.mats) do
    if rewriteMaterial(name, rec, mult) then ok = ok + 1 else bad = bad + 1 end
  end
  st.okCount, st.failCount = ok, bad
end

-- 1.0: a rewrite spread over the next frames, APPLY_BUDGET_MS per frame (at least one material)
local function startJob(mult)
  local names = {}
  for name in pairs(st.mats) do names[#names + 1] = name end
  st.job = { mult = mult, names = names, i = 1, ok = 0, bad = 0 }
end

local function stepJob()
  local job = st.job
  if not job then return end
  local t0 = os.clock()
  repeat
    local name = job.names[job.i]
    if not name then break end
    job.i = job.i + 1
    if rewriteMaterial(name, st.mats[name], job.mult) then job.ok = job.ok + 1 else job.bad = job.bad + 1 end
  until (os.clock() - t0) * 1000 >= APPLY_BUDGET_MS
  if job.i > #job.names then
    st.okCount, st.failCount = job.ok, job.bad
    st.job = nil
  end
end

local function restoreMaterials()
  if st.appliedWet ~= -1 and st.matCount > 0 then applyRoughnessMultiplier(1.0) end
  st.appliedWet = -1
  st.appliedMult = 1
  st.wet = 0
end

-- ---------------------------------------------------------------------------------------------------------------
-- native SSR quality
-- ---------------------------------------------------------------------------------------------------------------
local function updateSsr(raining, cfg)
  local want = math.floor((tonumber(cfg.nativeSsrQuality) or 0) + 0.5)
  local cur = getSetting('PostFXSSRQuality')
  if want >= 1 and SSR_QUALITY[want] then
    if raining or not cfg.nativeSsrRestore then
      if cur ~= SSR_QUALITY[want] then
        if st.ssrPrev == nil then st.ssrPrev = cur or 'Off' end
        setSetting('PostFXSSRQuality', SSR_QUALITY[want])
      end
    elseif st.ssrPrev ~= nil and cfg.nativeSsrRestore then
      setSetting('PostFXSSRQuality', st.ssrPrev)
      st.ssrPrev = nil
    end
  elseif st.ssrPrev ~= nil then
    setSetting('PostFXSSRQuality', st.ssrPrev)       -- user switched back to "keep game setting"
    st.ssrPrev = nil
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- public API
-- ---------------------------------------------------------------------------------------------------------------
-- 1 when the native PBR path is carrying the wet-road reflection, so the compute shader must not draw a second film.
M.nativeFilm = function(cfg)
  local mode = math.floor((tonumber(cfg.reflectionMode) or 0) + 0.5)
  if mode == 2 then return 0 end           -- "Own SSR only"
  if mode == 1 then return 1 end           -- "Native PBR + SSR"
  return 0                                 -- 1.0 Auto: the mod's own film (see M.update)
end

-- 1.0: only the "Native PBR + SSR" mode (reflectionMode 1) changes the road materials. Auto no longer does: the
-- wetness changes all the time (rain, flood, tunnels: the materials are shared by every road of the level, so wet ones
-- also shone in tunnels), each rewrite stalled the game, and the mod's own film draws the same wet road without that
-- (and keeps covered ground dry). dryNear (roofs near the camera) is no longer used here.
M.update = function(dt, rain, cfg, flood, dryNear)
  dt = tonumber(dt) or 0
  st.clock = st.clock + dt

  local lvl = nil
  pcall(function() lvl = getCurrentLevelIdentifier() end)
  if lvl ~= st.level then
    st.level = lvl
    st.mats, st.matCount, st.okCount, st.failCount = {}, 0, 0, 0   -- objects of the old level are gone
    st.appliedWet, st.wet, st.lastScan = -1, 0, -1e9
    st.appliedMult, st.settingKey, st.job = 1, nil, nil
    st.status = 'idle'
  end
  stepJob()

  local mode = math.floor((tonumber(cfg.reflectionMode) or 0) + 0.5)
  local enabled = cfg.enabled and cfg.wetGround ~= false and cfg.wetRoadMaterials and mode == 1
  rain = clamp(tonumber(rain) or 0, 0, 1)
  local target = 0
  local wetScale = clamp(tonumber(cfg.roadWetness) or 1, 0, 1)
  if enabled and rain > 0.02 then target = (rain ^ 0.7) * wetScale end
  st.target = target

  -- smooth wetness: gets wet in a few seconds, dries more slowly
  local rate = (target > st.wet) and 0.25 or 0.08
  st.wet = st.wet + (target - st.wet) * (1 - math.exp(-rate * dt))
  if math.abs(target - st.wet) < 0.003 then st.wet = target end

  if st.wet > 0.05 and st.matCount == 0 and st.clock - st.lastScan > 10 then rescan() end

  -- 0.8 ground model (same curve as the shader):
  --   target roughness = 'Roughness when wet' (fraction of the dry value), going to the puddle's water roughness as
  --                      the road floods ('Puddle-like at max rain')
  --   amount           = wetness x 'Reflection strength'; the strength stops mattering as it floods, so a flooded road
  --                      matches the puddles 1:1
  flood = clamp(tonumber(flood) or 0, 0, 1)
  local wetRough = clamp(tonumber(cfg.roadRoughness) or 0.40, 0.05, 1)
  local strength = clamp(tonumber(cfg.roadReflection) or 0.6, 0, 1)
  local floodRough = clamp((tonumber(cfg.puddleRoughness) or 0.18) * 0.5 / 0.8, 0.03, 1)   -- water vs dry asphalt (~0.8)
  local targetRough = wetRough + (floodRough - wetRough) * flood
  local amount = st.wet * (strength + (1 - strength) * flood)
  local mult = 1 - (1 - targetRough) * amount
  local diff = math.abs(mult - (st.appliedMult or 1))
  local settingKey = string.format('%.3f|%.3f|%.3f', wetRough, strength, floodRough)
  local drying = (st.wet == 0 and st.appliedWet > 0)
  -- slider edits apply after 0.25 s, rain-driven changes at most every 2 s and in steps of 0.05 (1.0), each spread
  -- over the next frames
  local interval = (settingKey ~= st.settingKey) and 0.25 or APPLY_INTERVAL
  if enabled and not st.job and st.matCount > 0 and st.clock - st.lastApply >= interval
     and (diff >= APPLY_STEP or drying or (settingKey ~= st.settingKey and diff >= 0.005)) then
    st.lastApply = st.clock
    startJob(mult)
    stepJob()
    st.appliedWet = st.wet
    st.appliedMult = mult
    st.settingKey = settingKey
    st.status = string.format('ok: %d road materials, %.0f%% wet, roughness x%.2f%s', st.matCount,
      st.wet * 100, mult, flood > 0.01 and string.format(', %.0f%% flooded', flood * 100) or '')
  elseif not enabled and st.appliedWet ~= -1 then
    restoreMaterials()
    st.status = 'restored'
  elseif not enabled and mode ~= 1 then
    st.status = 'not used: the mod draws the wet road (Auto / Own)'
  end
  if enabled and st.okCount == 0 and st.failCount > 0 and not st.job then
    st.status = 'material API did not accept the change' .. (st.lastErr and (' (' .. st.lastErr .. ')') or '')
  end

  if st.clock - st.lastSsr >= SSR_INTERVAL then
    st.lastSsr = st.clock
    updateSsr(rain > 0.02, cfg)
  end
end

M.getStatus = function()
  local q = getSetting('PostFXSSRQuality')
  return {
    status = st.status,
    wetness = st.wet,
    matCount = st.matCount,
    okCount = st.okCount,
    failCount = st.failCount,
    lastError = st.lastErr,
    ssr = {
      supported = ssrSupported(),
      objectPresent = scenetree.findObject('PostFxSSSRObject') ~= nil,
      quality = q ~= nil and tostring(q) or 'unknown',
      available = getSetting('PostFXSSRAvailable'),
      raisedByMod = st.ssrPrev ~= nil,
    },
  }
end

M.restoreAll = function()
  restoreMaterials()
  if st.ssrPrev ~= nil then
    setSetting('PostFXSSRQuality', st.ssrPrev)
    st.ssrPrev = nil
  end
  st.status = 'restored'
end

M.rescan = function() rescan() return st.matCount end

M.onExtensionUnloaded = function() M.restoreAll() end

return M
