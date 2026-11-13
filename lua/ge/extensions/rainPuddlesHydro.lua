-- rainPuddlesHydro.lua (game engine Lua) - the GE half of node-based hydroplaning (Rain Puddles & Droplets 1.0)
--
-- The physics runs in each car's own Lua (lua/vehicle/extensions/rainPuddlesHydroVeh.lua, at the physics rate, node by
-- node). This side loads it into the player's car (and traffic, if enabled), and answers each car's report of where
-- its tyres are with what only the game engine side knows: the puddle field of the moment (coverage, size, softness,
-- tiling, which masks, how deep the film and the puddles are, all from rainPuddles' own settings and wetness), the
-- road lanes around each tyre (the roads-only puddle mask) and whether a roof or a tunnel is above it.

local M = {}
local TAG = 'rainPuddlesHydro'

local st = { t = 0, scanAt = -1e9, envAt = -1e9, envStr = nil, env = nil, cars = {}, status = nil, statusAt = -1e9 }
local CMD_LOAD = "if not rainPuddlesHydroVeh then extensions.load('rainPuddlesHydroVeh') end"
local CMD_UNLOAD = "if rainPuddlesHydroVeh then extensions.unload('rainPuddlesHydroVeh') end"

local function num(x)
  x = tonumber(x) or 0
  if x ~= x or math.abs(x) < 1e-6 then return '0' end             -- never a denormal / NaN (LuaJIT prints garbage)
  return string.format('%.4f', x)
end

local function envString(e)
  return string.format(
    '{enabled=%s,mode=%d,strength=%s,tread=%s,debug=%s,puddles=%s,roadsOnly=%s,tile=%s,cov=%s,sizeWarp=%s,soft=%s,fieldA=%q,fieldB=%q,hFilm=%s,hPuddle=%s}',
    tostring(e.enabled), e.mode, num(e.strength), num(e.tread), tostring(e.debug), tostring(e.puddles), tostring(e.roadsOnly),
    num(e.tile), num(e.cov), num(e.sizeWarp), num(e.soft), e.fieldA, e.fieldB, num(e.hFilm), num(e.hPuddle))
end

local function currentEnv()
  if st.t - st.envAt < 0.25 and st.env then return st.env, st.envStr end
  local rp = extensions.rainPuddles
  local ok, e = false, nil
  if rp and rp.hydroEnv then ok, e = pcall(rp.hydroEnv) end
  if not ok or type(e) ~= 'table' then e = { enabled = false, mode = 0, strength = 1, tread = 7, debug = false, puddles = false,
    roadsOnly = false, tile = 44, cov = 0, sizeWarp = 1, soft = 0.035, fieldA = '', fieldB = '', hFilm = 0, hPuddle = 0 } end
  st.env, st.envStr, st.envAt = e, envString(e), st.t
  return st.env, st.envStr
end

-- a car reports its tyres (name x y z of each contact point); it gets the field and, per tyre, lanes and roofs back
M.onWheels = function(vid, payload)
  vid = tonumber(vid)
  if not vid or type(payload) ~= 'string' then return end
  local car = st.cars[vid] or {}
  st.cars[vid] = car
  car.seen = st.t
  local veh = be:getObjectByID(vid)
  if not veh then return end
  local e, es = currentEnv()
  local rp = extensions.rainPuddles
  local parts = {}
  if e.enabled then
    for name, x, y, z in payload:gmatch('([^%s;]+) ([^%s;]+) ([^%s;]+) ([^%s;]+)') do
      x, y, z = tonumber(x), tonumber(y), tonumber(z)
      if x and y and z then
        local open = 1
        if rp and rp.hydroCovered then
          local okC, c = pcall(rp.hydroCovered, x, y, z, vid)
          if okC and tonumber(c) then open = 1 - math.max(0, math.min(1, c)) end
        end
        local segStr = 'nil'
        if e.roadsOnly and rp and rp.hydroRoads then
          local okR, segs = pcall(rp.hydroRoads, x, y, z, 3)
          if okR and type(segs) == 'table' then
            local s = {}
            for _, g in ipairs(segs) do
              s[#s + 1] = string.format('{%s,%s,%s,%s,%s,%s,%s,%s}', num(g[1]), num(g[2]), num(g[3]), num(g[4]),
                num(g[5]), num(g[6]), num(g[7]), num(g[8]))
            end
            segStr = '{' .. table.concat(s, ',') .. '}'
          end
        end
        parts[#parts + 1] = string.format('[%q]={open=%s,segs=%s}', name, num(open), segStr)
      end
    end
  end
  pcall(function() veh:queueLuaCommand('if rainPuddlesHydroVeh then rainPuddlesHydroVeh.setEnv(' .. es .. ',{' .. table.concat(parts, ',') .. '}) end') end)
end

-- the player's car: per tyre "name lift depth speed pressure"
M.onStatus = function(vid, payload)
  if type(payload) ~= 'string' then return end
  local tyres = {}
  for name, lam, depth, kmh, kpa in payload:gmatch('([^%s;]+) ([^%s;]+) ([^%s;]+) ([^%s;]+) ([^%s;]+)') do
    tyres[#tyres + 1] = { name = name, lift = tonumber(lam) or 0, depthMm = (tonumber(depth) or 0) * 1000,
                          kmh = tonumber(kmh) or 0, kPa = tonumber(kpa) or 0 }
  end
  st.status, st.statusAt, st.statusVid = tyres, st.t, tonumber(vid)
end

M.getStatus = function()
  local e = st.env or {}
  local n = 0
  for _, car in pairs(st.cars) do if st.t - (car.seen or -1e9) < 2 then n = n + 1 end end
  local names = { [0] = 'off', 'arcade', 'simcade', 'sim' }
  return { mode = names[e.mode or 0] or 'off', enabled = e.enabled and true or false, cars = n,
           filmMm = (e.hFilm or 0) * 1000, puddleMm = (e.hPuddle or 0) * 1000,
           tyres = (st.t - st.statusAt < 1.5) and st.status or nil }
end

-- every 2 s: the player's car (and traffic within 400 m, if enabled) carries the vehicle half; it is unloaded again
-- when hydroplaning is switched off
M.onUpdate = function(dtReal)
  st.t = st.t + (tonumber(dtReal) or 0)
  if st.t - st.scanAt < 2 then return end
  st.scanAt = st.t
  local e = currentEnv()
  local playerId = be:getPlayerVehicleID(0)
  local cx, cy, cz = 0, 0, 0
  pcall(function() local p = core_camera.getPosition() cx, cy, cz = p.x, p.y, p.z end)
  local seenNow = {}
  for i = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(i)
    local vid = veh and veh:getID()
    if vid then
      seenNow[vid] = true
      local car = st.cars[vid] or {}
      st.cars[vid] = car
      local want = e.enabled and (vid == playerId or e.traffic)
      if want and vid ~= playerId then
        local p = veh:getPosition()
        local dx, dy, dz = p.x - cx, p.y - cy, p.z - cz
        want = dx * dx + dy * dy + dz * dz < 400 * 400
      end
      if want then
        -- (again when the car has not reported for a while: respawned or reloaded cars lose their vehicle Lua)
        if not car.loaded or st.t - (car.seen or -1e9) > 3 then
          car.loaded, car.seen = true, st.t
          pcall(function() veh:queueLuaCommand(CMD_LOAD) end)
        end
      elseif car.loaded then
        car.loaded = false
        pcall(function() veh:queueLuaCommand(CMD_UNLOAD) end)
      end
    end
  end
  for vid in pairs(st.cars) do if not seenNow[vid] then st.cars[vid] = nil end end
end

M.onVehicleSpawned = function(vid)
  local car = st.cars[vid]
  if car then car.loaded = false end
  st.scanAt = -1e9
end

M.onExtensionUnloaded = function()
  for i = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(i)
    if veh then pcall(function() veh:queueLuaCommand(CMD_UNLOAD) end) end
  end
end

return M
