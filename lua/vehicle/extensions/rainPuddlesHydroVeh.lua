-- rainPuddlesHydroVeh.lua (vehicle Lua) - node-based hydroplaning for Rain Puddles & Droplets 1.0
--
-- Water on the road lifts and drags every tyre's contact patch, node by node:
--  * Which tread nodes touch the road: each tyre's tread nodes are put in ring order around the axle from the rest pose
--    (spokes); the lowest spoke is followed as the wheel turns, and the patch is that spoke and its neighbours.
--  * How deep the water is under each of those nodes: the road's water film plus the puddles, from exactly the puddle
--    field the shader draws (the same 512 x 512 masks, world-space tiling, coverage cut and depth ramp), only inside the
--    road lanes and never under a roof (lanes and roofs from the GE side, lua/ge/extensions/rainPuddlesHydro.lua). Water
--    only stands on hard ground (asphalt, concrete, cobbles...); dirt, grass and sand soak it up.
--  * What the tread can drain: the groove volume of the tyre (tread depth by tyre type, or the setting), less at speed.
--  * The water pressure that builds in front of the patch: 1/2 rho v^2 C_L against the tyre's own inflation pressure
--    (the classic aquaplaning balance; with C_L 0.7 a 2.2 bar tyre floats at about 95 km/h, close to Horne's
--    V = 6.36 sqrt(p kPa) km/h). That share of each node's load is carried by the water: the node is pushed up off the
--    road, so BeamNG's own tyre model loses the grip there (no friction value is changed).
--  * The water the tyre has to push aside: drag 1/2 rho C_D v^2 (depth x width) on the leading nodes, which slows the
--    wheel (spin-down) and pulls the car toward the deeper side when only some tyres are in the water.
-- Arcade / simcade / sim scale the lift coefficient, the drag, the most load the water can carry and the depth it needs.

local M = {}
local TAG = 'rainPuddlesHydro'

local abs, min, max, sqrt, floor, exp, atan2 = math.abs, math.min, math.max, math.sqrt, math.floor, math.exp, math.atan2
local byte = string.byte

local RHO = 1000                  -- water density (kg/m^3)
local FN = 512                    -- field resolution (texels)
local EVAL_EVERY = 4              -- physics steps between water / force evaluations (2000 Hz physics: 500 Hz)
local FIELD_SUM = {               -- weighted checksums of the raw fields (art/rainPuddles/fields, made from the PNG masks)
  ['puddle_01_lakes.field'] = 598452771, ['puddle_02_scattered.field'] = 598913628,
  ['puddle_03_streaks.field'] = 602134487, ['puddle_04_patchy.field'] = 599267905,
  ['puddle_05_film.field'] = 599483639, ['puddle_06_lakes.field'] = 598120976,
  ['puddle_07_scattered.field'] = 598527163, ['puddle_08_streaks.field'] = 599094800,
  ['puddle_09_patchy.field'] = 598625487, ['puddle_10_film.field'] = 599387829,
  ['puddle_11_lakes.field'] = 597632484, ['puddle_12_scattered.field'] = 599995443,
}
-- cl: lift coefficient, cd: drag coefficient, lamMax: most of the load the water can carry, hFull: water above what the
-- tread drains that builds the full pressure (m)
-- (tested on the West Coast USA drag strip at 105 km/h through puddles, wheel held straight: with the first simcade
-- values, 0.55 / 80 %, the rear axle floated in a 10 mm puddle and the car spun; simcade now keeps 35 % of the grip)
local MODES = {
  [1] = { cl = 0.30, cd = 0.30, lamMax = 0.45, hFull = 0.0060, name = 'arcade' },
  [2] = { cl = 0.45, cd = 0.50, lamMax = 0.65, hFull = 0.0040, name = 'simcade' },
  [3] = { cl = 0.70, cd = 0.80, lamMax = 0.95, hFull = 0.0025, name = 'sim' },
}
-- ground models water stands on (lua/common/particles.json names)
local HARD = { ASPHALT = true, ASPHALT_WET = true, ROCK = true, COBBLESTONE = true, RUMBLE_STRIP = true, METAL = true,
               WOOD = true, PLASTIC = true, SLIPPERY = true }
-- tread depth by tyre type (part name), m; anything else uses the setting
local TREAD_BY_TYPE = { { 'slick', 0.0005 }, { 'semi', 0.0025 }, { 'drag', 0.001 }, { 'race', 0.004 },
                        { 'offroad', 0.011 }, { 'allterrain', 0.010 }, { 'mud', 0.013 }, { 'snow', 0.010 } }

local env = nil                   -- latest field + settings from GE (setEnv)
local wheelEnv = {}               -- [wheel name] = { open = 0..1, segs = { {ax, ay, az, ra, bx, by, bz, rb}, ... } }
local fields = {}                 -- [file name] = raw byte string, or false = could not be read
local fieldA, fieldB = nil, nil
local hy = {}                     -- per-wheel state
local matName = {}
local active = false
local hookOn = false
local stepN = 0
local clock = 0
local lastReq, lastStatus = -1e9, -1e9
local vecF = nil
local warned = {}

local function warnOnce(key, msg)
  if not warned[key] then warned[key] = true log('W', TAG, msg) end
end

local function clamp01(x) if x < 0 then return 0 elseif x > 1 then return 1 end return x end
local function smoothstep(a, b, x)
  local t = (x - a) / (b - a)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return t * t * (3 - 2 * t)
end

-- fields ---------------------------------------------------------------------------------------------------------------
local function loadField(name)
  if fields[name] ~= nil then return fields[name] or nil end
  local s = nil
  local ok = pcall(function()
    local f = io.open('/art/rainPuddles/fields/' .. name, 'rb')
    if f then s = f:read('*a') f:close() end
  end)
  if not ok or type(s) ~= 'string' or #s ~= FN * FN then
    fields[name] = false
    warnOnce('field_' .. name, 'puddle field ' .. name .. ' could not be read (' .. tostring(s and #s) .. ' bytes): film only')
    return nil
  end
  local want = FIELD_SUM[name]
  if want then
    local c = 0
    for i = 0, #s - 1, 7 do c = (c + byte(s, i + 1) * ((i % 251) + 1)) % 4294967296 end
    if c ~= want then
      fields[name] = false
      warnOnce('sum_' .. name, 'puddle field ' .. name .. ' is damaged (checksum): film only')
      return nil
    end
  end
  fields[name] = s
  return s
end

-- bilinear, wrapping, texel centres at +0.5 (exactly rpSampleFieldMip at mip 0)
local function sampleField(s, u, v)
  local px = (u - floor(u)) * FN - 0.5
  local py = (v - floor(v)) * FN - 0.5
  local x0, y0 = floor(px), floor(py)
  local fx, fy = px - x0, py - y0
  local ax, ay = x0 % FN, y0 % FN
  local bx, by = (x0 + 1) % FN, (y0 + 1) % FN
  local r0, r1 = ay * FN + 1, by * FN + 1
  local v00, v10 = byte(s, r0 + ax), byte(s, r0 + bx)
  local v01, v11 = byte(s, r1 + ax), byte(s, r1 + bx)
  local a = v00 + (v10 - v00) * fx
  local b = v01 + (v11 - v01) * fx
  return (a + (b - a) * fy) * (1 / 255)
end

-- puddle amount and depth ramp at world xy (rp_puddles.cs.hlsl: shape, cut, puddle, depthP)
local function puddleAt(x, y)
  local e = env
  local tile = e.tile
  local nA = sampleField(fieldA, x / tile, y / tile)
  local tb = tile * 0.57
  local nB = sampleField(fieldB, (x * 0.8660254 - y * 0.5) / tb + 0.37, (x * 0.5 + y * 0.8660254) / tb + 0.61)
  local shape = clamp01(0.5 + (nA - 0.5) / max(e.sizeWarp, 0.1))
  local cut = (1 - e.cov) + (nB - 0.5) * 0.32 * min(e.cov * 4, 1)
  return smoothstep(cut, cut + e.soft, shape), smoothstep(cut, cut + 0.22, shape)
end

-- inside the road lanes (the shader's roads-only mask, from the lane segments GE sent for this wheel)
local function roadMaskAt(we, x, y, z)
  local segs = we and we.segs
  if not segs then return 1 end
  local m = 0
  for i = 1, #segs do
    local s = segs[i]
    local abx, aby = s[5] - s[1], s[6] - s[2]
    local t = clamp01(((x - s[1]) * abx + (y - s[2]) * aby) / max(abx * abx + aby * aby, 1e-4))
    local dx, dy = x - (s[1] + abx * t), y - (s[2] + aby * t)
    local d = sqrt(dx * dx + dy * dy)
    local r = s[4] + (s[8] - s[4]) * t
    local zS = s[3] + (s[7] - s[3]) * t
    local mm = (1 - smoothstep(r - 0.25, r + 0.35, d)) * (1 - smoothstep(1.0, 2.2, abs(z - zS)))
    if mm > m then m = mm end
  end
  return m
end

-- water depth (m) at a world point under wheel w
local function waterDepth(w, we, x, y, z)
  local e = env
  local open = we and we.open or 1
  local h = e.hFilm
  if fieldA and fieldB and e.puddles and e.cov > 0.001 then
    local pud, dep = puddleAt(x, y)
    if pud > 0.001 then
      local road = (e.roadsOnly and we and we.segs) and roadMaskAt(we, x, y, z) or 1
      h = h + e.hPuddle * pud * dep * road
    end
  end
  return h * open * w.clear
end

-- tyres -------------------------------------------------------------------------------------------------------------------
-- the chosen tyre parts of the car (parts tree): F = front, R = rear (from the slot, e.g. .../tire_F_20x9/), any = first
local tyreParts = {}
local function findTyreParts()
  tyreParts = {}
  local function walk(n, depth)
    if type(n) ~= 'table' or depth > 40 then return end
    local pn = n.chosenPartName
    if type(pn) == 'string' and pn:lower():find('tire', 1, true) then
      local where = (tostring(n.path or '') .. '/' .. pn):lower()
      local side = where:find('tire_f', 1, true) and 'F' or (where:find('tire_r', 1, true) and 'R' or nil)
      if side and not tyreParts[side] then tyreParts[side] = pn end
      tyreParts.any = tyreParts.any or pn
    end
    for _, c in pairs(n.children or {}) do walk(c, depth + 1) end
  end
  pcall(walk, v.config and v.config.partsTree, 0)
end

local function buildWheel(wid, wd)
  local tread = wd.treadNodes
  local nodes = v.data.nodes
  if type(tread) ~= 'table' or #tread < 6 or not (wd.node1 and wd.node2) then return nil end
  local n1, n2 = nodes[wd.node1], nodes[wd.node2]
  if not (n1 and n2 and n1.pos and n2.pos) then return nil end
  local ax, ay, az = n2.pos.x - n1.pos.x, n2.pos.y - n1.pos.y, n2.pos.z - n1.pos.z
  local al = sqrt(ax * ax + ay * ay + az * az)
  if al < 1e-4 then return nil end
  ax, ay, az = ax / al, ay / al, az / al
  local cx, cy, cz = (n1.pos.x + n2.pos.x) * 0.5, (n1.pos.y + n2.pos.y) * 0.5, (n1.pos.z + n2.pos.z) * 0.5
  local list = {}
  local e1x, e1y, e1z, e2x, e2y, e2z
  local latMin, latMax = math.huge, -math.huge
  for _, cid in ipairs(tread) do
    local nd = nodes[cid]
    if nd and nd.pos then
      local rx, ry, rz = nd.pos.x - cx, nd.pos.y - cy, nd.pos.z - cz
      local lat = rx * ax + ry * ay + rz * az
      rx, ry, rz = rx - ax * lat, ry - ay * lat, rz - az * lat
      if not e1x then
        local l = sqrt(rx * rx + ry * ry + rz * rz)
        if l < 1e-4 then return nil end
        e1x, e1y, e1z = rx / l, ry / l, rz / l
        e2x, e2y, e2z = ay * e1z - az * e1y, az * e1x - ax * e1z, ax * e1y - ay * e1x
      end
      list[#list + 1] = { cid = cid, ang = atan2(rx * e2x + ry * e2y + rz * e2z, rx * e1x + ry * e1y + rz * e1z), lat = lat }
      latMin, latMax = min(latMin, lat), max(latMax, lat)
    end
  end
  if #list < 6 then return nil end
  table.sort(list, function(a, b) return a.ang < b.ang end)
  -- spokes: nodes at (about) the same angle across the tread. Multi-row tyres have tiny gaps within a spoke.
  local meanGap = 2 * math.pi / #list
  local gaps = {}
  for i = 1, #list do
    local nx = list[i % #list + 1].ang + ((i == #list) and 2 * math.pi or 0)
    gaps[i] = nx - list[i].ang
  end
  local sorted = {}
  for i, g in ipairs(gaps) do sorted[i] = g end
  table.sort(sorted)
  local multiRow = sorted[max(1, floor(#sorted * 0.3))] < 0.3 * meanGap
  local spokes = {}
  local cur = { nodes = { list[1].cid } }
  for i = 2, #list do
    if multiRow and (list[i].ang - list[i - 1].ang) < meanGap then
      cur.nodes[#cur.nodes + 1] = list[i].cid
    else
      spokes[#spokes + 1] = cur
      cur = { nodes = { list[i].cid } }
    end
  end
  spokes[#spokes + 1] = cur
  if multiRow and #spokes > 2 and (list[1].ang + 2 * math.pi - list[#list].ang) < meanGap then
    -- the first and last spokes are one (the ring closes in the middle of a spoke)
    for _, cid in ipairs(spokes[1].nodes) do spokes[#spokes].nodes[#spokes[#spokes].nodes + 1] = cid end
    table.remove(spokes, 1)
  end
  if #spokes < 6 then return nil end
  for _, s in ipairs(spokes) do s.ref = s.nodes[1] end
  -- tyre type from the tyre part's name (the front or rear tyre of the parts tree), width from the jbeam (or the tread)
  local nm = tostring(wd.name or '')
  local part = (tyreParts[nm:sub(1, 1)] or tyreParts.any or ''):lower()
  local treadDepth = nil
  for _, t in ipairs(TREAD_BY_TYPE) do if part:find(t[1], 1, true) then treadDepth = t[2] break end end
  local width = (wd.tireWidth and wd.tireWidth > 0.05) and wd.tireWidth or max(latMax - latMin, 0.1)
  local radius = wd.radius or 0.3
  local arc = 2 * math.pi * radius / #spokes
  local w = {
    wid = wid, name = wd.name or tostring(wid), wd = wd, hub = wd.node1, spokes = spokes, ns = #spokes,
    m = max(1, floor((0.06 + 0.12 * radius) / max(arc, 0.01) + 0.5)), width = width, radius = radius,
    treadType = treadDepth, treadDepth = treadDepth, rows = 0, k = nil, on = false, load = 0, liftPrev = 0,
    pressure = 200000, clear = 1, lam = {}, fx = {}, fy = {}, fz = {}, slotCid = {}, nSlots = 0, part = part,
    front = nil, vh = 0, lamAvg = 0, depthMax = 0,
  }
  for _, s in ipairs(spokes) do w.rows = max(w.rows, #s.nodes) end
  return w
end

local function buildAll()
  hy = {}
  if not (wheels and wheels.wheels) then return end
  findTyreParts()
  pcall(function()
    local mats = particles.getMaterialsParticlesTable()
    for id, mt in pairs(mats or {}) do matName[id] = mt and mt.name end
  end)
  -- the car's weight per tyre (node masses), for the load cap
  local mass = 0
  for _, n in pairs(v.data.nodes or {}) do mass = mass + (tonumber(n.nodeWeight) or 0) end
  local ids = {}
  for wid in pairs(wheels.wheels) do ids[#ids + 1] = wid end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  for _, wid in ipairs(ids) do
    local wd = wheels.wheels[wid]
    if wd and (wd.hasTire == nil or wd.hasTire) then
      local ok, w = pcall(buildWheel, wid, wd)
      if ok and w then hy[#hy + 1] = w end
    end
  end
  local perTyre = (mass > 0 and #hy > 0) and mass * 9.81 / #hy or 4000
  for _, w in ipairs(hy) do w.loadCap = 3 * perTyre end
  -- front / rear: a rear tyre rolls in the track a front tyre on its side has just cleared
  for _, w in ipairs(hy) do
    local nm = tostring(w.name)
    if nm:sub(1, 1) == 'R' then
      for _, f in ipairs(hy) do
        if tostring(f.name) == 'F' .. nm:sub(2) then w.front = f end
      end
    end
  end
  log('I', TAG, string.format('%d tyres prepared (%s)', #hy, (function()
    local o = {}
    for _, w in ipairs(hy) do o[#o + 1] = string.format('%s: %d spokes x %d, patch %d, %.2f m wide%s', w.name, w.ns, w.rows,
      2 * w.m + 1, w.width, w.treadType and string.format(', tread %.1f mm (type)', w.treadType * 1000) or '') end
    return table.concat(o, '; ')
  end)()))
end

-- the spoke of w that is lowest (on the road) now, followed from the last one as the wheel turns
local function spokeZ(w, k)
  local p = obj:getNodePosition(w.spokes[(k - 1) % w.ns + 1].ref)
  return p.z
end

local function track(w)
  local k = w.k
  if not k then
    local bestK, bestZ = 1, math.huge
    for i = 1, w.ns do
      local z = spokeZ(w, i)
      if z < bestZ then bestK, bestZ = i, z end
    end
    w.k = bestK
    return
  end
  for _ = 1, 4 do
    local z0, zm, zp = spokeZ(w, k), spokeZ(w, k - 1), spokeZ(w, k + 1)
    if zm < z0 and zm <= zp then k = k - 1
    elseif zp < z0 then k = k + 1
    else break end
  end
  w.k = (k - 1) % w.ns + 1
end

-- water, lift and drag of one tyre's patch (every EVAL_EVERY physics steps)
local function evaluate(w, dtEval, ox, oy, oz, mode, strength)
  local vel = obj:getNodeVelocityVector(w.hub)
  local vx, vy = vel.x, vel.y
  local vh = sqrt(vx * vx + vy * vy)
  w.vh = vh
  local dx, dy = 0, 0
  if vh > 0.1 then dx, dy = vx / vh, vy / vh end
  local q = 0.5 * RHO * vh * vh
  local p = max(w.pressure, 60000)
  local drain = (w.treadDepth or env.tread) * 0.35 / (1 + vh / 40)
  local kS = 1 - exp(-dtEval / 0.02)
  local we = wheelEnv[w.name]
  -- The tyre's load WITHOUT the water's share (w.Lref, see updateGFX). 1.0 fix: this used to be "road force the game
  -- measures + the lift already applied", but the measured force does not drop by all of the lift, so the lift fed
  -- itself (at 65 % it settled near 1.9x the tyre's load) and flung the car into the air.
  local L = w.Lref or w.load
  -- the water never carries more than 95 % of a tyre's load, whatever the strength: it can lighten a car, never lift it
  local lamCap = min(mode.lamMax * strength, 0.95)
  local wsum = 0
  for o = -w.m, w.m do wsum = wsum + (w.m + 1 - abs(o)) end
  local liftSum, lamSum, lamN, depthMax = 0, 0, 0, 0
  local slot = 0
  for o = -w.m, w.m do
    local spoke = w.spokes[(w.k + o - 1) % w.ns + 1]
    local share = (w.m + 1 - abs(o)) / wsum / #spoke.nodes        -- this node's part of the patch (all add up to 1)
    for _, cid in ipairs(spoke.nodes) do
      slot = slot + 1
      local np = obj:getNodePosition(cid)
      local h = waterDepth(w, we, ox + np.x, oy + np.y, oz + np.z)
      depthMax = max(depthMax, h)
      -- the water pressure ahead of this node against the tyre's pressure, once more water stands than the tread drains
      local over = h - drain
      local g = (over > 0) and smoothstep(0, mode.hFull, over) or 0
      local lam = min(mode.cl * q * g / p * strength, lamCap)
      local lp = (w.lam[slot] or 0)
      lp = lp + (lam - lp) * kS
      w.lam[slot] = lp
      local up = lp * L * share                                      -- at most 95 % of the load this node carries
      liftSum = liftSum + up
      lamSum, lamN = lamSum + lp, lamN + 1
      -- the water the tyre pushes aside: depth x tyre width, spread over the patch (not one tread node)
      local drag = (h > 0.0002) and 0.5 * RHO * mode.cd * vh * vh * h * w.width * share * strength or 0
      w.fx[slot], w.fy[slot], w.fz[slot] = -dx * drag, -dy * drag, up
      w.slotCid[slot] = cid
    end
  end
  w.nSlots = slot
  w.liftPrev = liftSum
  w.lamAvg = (lamN > 0) and lamSum / lamN or 0
  w.depthMax = depthMax
end

local function clearWheel(w)
  w.nSlots, w.liftPrev, w.lamAvg = 0, 0, 0
  for i in pairs(w.lam) do w.lam[i] = 0 end
end

-- hooks -------------------------------------------------------------------------------------------------------------------
M.onPhysicsStep = function(dtPhys)
  if not active then return end
  stepN = stepN + 1
  local mode = MODES[env.mode]
  if not mode then return end
  local evalNow = (stepN % EVAL_EVERY == 0)
  local ox, oy, oz = 0, 0, 0
  if evalNow then ox, oy, oz = obj:getPositionXYZ() end
  local strength = env.strength
  for i = 1, #hy do
    local w = hy[i]
    if w.on then
      track(w)
      if evalNow then evaluate(w, dtPhys * EVAL_EVERY, ox, oy, oz, mode, strength) end
      -- the forces of each patch slot go to the node that is in that slot now
      local slot = 0
      for o = -w.m, w.m do
        local spoke = w.spokes[(w.k + o - 1) % w.ns + 1]
        for _, cid in ipairs(spoke.nodes) do
          slot = slot + 1
          local fz = w.fz[slot]
          if fz and (fz > 0.5 or abs(w.fx[slot]) > 0.5 or abs(w.fy[slot]) > 0.5) then
            vecF:set(w.fx[slot], w.fy[slot], fz)
            obj:applyForceVector(cid, vecF)
          end
        end
      end
    end
  end
end

local function sendGE(cmd)
  pcall(function() obj:queueGameEngineLua(cmd) end)
end

M.updateGFX = function(dt)
  clock = clock + (dt or 0)
  local mode = env and MODES[env.mode]
  local enabled = env and env.enabled and mode ~= nil
  -- ask GE for the lanes / roofs around the tyres (and the field) a few times a second
  if clock - lastReq > 0.25 then
    lastReq = clock
    local ox, oy, oz = obj:getPositionXYZ()
    local parts = {}
    for _, w in ipairs(hy) do
      local p = obj:getNodePosition(w.hub)
      parts[#parts + 1] = string.format('%s %.2f %.2f %.2f', w.name, ox + p.x, oy + p.y, oz + p.z - w.radius)
    end
    sendGE(string.format("if extensions.rainPuddlesHydro then extensions.rainPuddlesHydro.onWheels(%d, %q) end",
      obj:getID(), table.concat(parts, ';')))
  end
  if not enabled then
    if active then for _, w in ipairs(hy) do clearWheel(w) w.on = false end end
    active = false
    return
  end
  if env.puddles then
    fieldA, fieldB = loadField(env.fieldA), loadField(env.fieldB)
  end
  local anyOn = false
  for _, w in ipairs(hy) do
    local wd = w.wd
    w.load = max(tonumber(wd.downForce) or 0, 0)
    -- the tyre's own load, without the water's share: followed while the water carries (almost) nothing, held while
    -- it does (the road force drops then), and never above 3x the car's weight per tyre (a hard landing)
    if not w.Lref or (w.lamAvg or 0) < 0.03 then
      local L0 = w.Lref or w.load
      w.Lref = L0 + (w.load - L0) * min((dt or 0) / 0.2, 1)
    end
    w.Lref = min(w.Lref, w.loadCap or 1e5)
    if clock - (w.pressAt or -1e9) > 0.5 then
      w.pressAt = clock
      pcall(function()
        local g = wd.pressureGroup and v.data.pressureGroups and v.data.pressureGroups[wd.pressureGroup]
        if g then w.pressure = max(obj:getGroupPressure(g) - obj:getEnvPressure(), 0) end
      end)
    end
    -- the ground under the tyre; while the water carries it the contact can come and go, so the last real ground
    -- counts for half a second
    local mat = wd.contactMaterialID1
    if mat == 4 then mat = wd.contactMaterialID2 end
    local name = matName[mat]
    if name then w.hard, w.hardAt = HARD[name] or false, clock
    elseif clock - (w.hardAt or -1e9) > 0.5 then w.hard = false end
    local intact = not (wd.isBroken or wd.isTireDeflated)
    local moving = abs(tonumber(wd.wheelSpeed) or 0) > 4 or w.vh > 4
    w.clear = 1
    if w.front and w.front.on and w.vh > 4 then w.clear = 1 - 0.35 * smoothstep(4, 12, w.vh) end
    -- the tyre's own load (road + water) keeps it on; a tyre in the air (road force under 2 % of its load, while the
    -- water can carry at most 95 %) gets nothing at all
    local airborne = (w.Lref or 0) > 50 and w.load < 0.02 * w.Lref
    local want = (w.hard and intact and moving and not airborne and (w.Lref or 0) > 50
                  and env.hFilm + env.hPuddle > 0.0002) or false
    if airborne and w.on then w.offAt = clock - 1 end                -- no hysteresis in the air
    if want then w.offAt = nil
    elseif w.on then
      w.offAt = w.offAt or clock
      if clock - w.offAt < 0.3 and intact then want = true end    -- hysteresis: brief contact gaps keep it on
    end
    if not want and w.on then clearWheel(w) end
    if want and not w.on then w.k = nil end
    w.on = want
    anyOn = anyOn or want
  end
  if anyOn and not hookOn then
    hookOn = true
    if type(enablePhysicsStepHook) == 'function' then enablePhysicsStepHook() end
  end
  active = anyOn
  -- the player's car reports its tyres for the settings panel
  if playerInfo and playerInfo.firstPlayerSeated and clock - lastStatus > 0.25 then
    lastStatus = clock
    local parts = {}
    for _, w in ipairs(hy) do
      parts[#parts + 1] = string.format('%s %.3f %.4f %.1f %.0f', w.name, w.lamAvg or 0, w.depthMax or 0, (w.vh or 0) * 3.6, (w.pressure or 0) / 1000)
    end
    sendGE(string.format("if extensions.rainPuddlesHydro then extensions.rainPuddlesHydro.onStatus(%d, %q) end", obj:getID(), table.concat(parts, ';')))
  end
  -- debug: every patch node, blue = water under it, red = how much of its load the water carries
  if env.debug and obj.debugDrawProxy then
    local ox, oy, oz = obj:getPositionXYZ()
    for _, w in ipairs(hy) do
      if w.on and w.k then
        local slot = 0
        for o = -w.m, w.m do
          local spoke = w.spokes[(w.k + o - 1) % w.ns + 1]
          for _, cid in ipairs(spoke.nodes) do
            slot = slot + 1
            local lam = w.lam[slot] or 0
            local p = obj:getNodePosition(cid)
            pcall(function()
              obj.debugDrawProxy:drawSphere(0.03 + 0.05 * lam, vec3(ox + p.x, oy + p.y, oz + p.z),
                color(255 * clamp01(lam * 1.2), 60, 255 * clamp01(1 - lam), 220))
            end)
          end
        end
      end
    end
  end
end

-- from GE (rainPuddlesHydro.lua): the field, the settings and, per tyre, the lanes and roofs around it
M.setEnv = function(e, perWheel)
  if type(e) ~= 'table' then return end
  env = e
  env.tread = max(tonumber(e.tread) or 7, 0) / 1000            -- the setting is in mm
  if type(perWheel) == 'table' then wheelEnv = perWheel end
end

M.getState = function()
  local o = { active = active, env = env and env.mode, tyres = {} }
  for _, w in ipairs(hy) do
    o.tyres[#o.tyres + 1] = { name = w.name, on = w.on, lam = w.lamAvg, depth = w.depthMax, vh = w.vh, pressure = w.pressure,
                              spokes = w.ns, rows = w.rows, patch = 2 * w.m + 1, width = w.width, tread = w.treadType, part = w.part }
  end
  o.fields = { a = env and env.fieldA, b = env and env.fieldB, okA = fieldA ~= nil, okB = fieldB ~= nil }
  return o
end

-- a reset rebuilds the game's wheel tables: the tyres are prepared again (the tread nodes stay the same)
M.onReset = function()
  active = false
  buildAll()
end

M.onExtensionLoaded = function()
  vecF = vec3(0, 0, 0)
  buildAll()
end

return M
