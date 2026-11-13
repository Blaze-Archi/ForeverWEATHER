-- rainPuddlesProbe.lua (vehicle Lua, one instance per vehicle)
--
-- Finds the REAL windshield of this vehicle, so the rain and the wipers sit on the actual glass instead of a plane
-- guessed from the bounding box. Mesh names differ on every car, so it works on geometry: the vehicle's own
-- collision triangles (jbeam triangles at their current node positions).
--   1. The probe idea from the mod's user: from the driver's eye go up to the roof, step 5 cm down, then go
--      forward until something is touched - normally the top of the windshield.
--   2. A fan of rays from the eye toward the front. The windshield is the surface in front of the eye that faces
--      forward; a robust plane fit (best triplet + inliers) separates it from the roof, dashboard and pillars.
-- The result (centre, normal, axes, half size) is sent to GE Lua in vehicle-local coordinates
-- (x right, y forward, z up, relative to the vehicle object position): extensions.rainPuddles.onWindshieldProbe().
-- Everything is guarded: if this build has no triangle data or a call differs, GE keeps its estimated plane.

local M = {}

local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function add(a, b, s) s = s or 1 return { a[1] + b[1] * s, a[2] + b[2] * s, a[3] + b[3] * s } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
local function len(a) return math.sqrt(dot(a, a)) end
local function norm(a)
  local l = len(a)
  if l < 1e-9 then return { 0, 0, 1 } end
  return { a[1] / l, a[2] / l, a[3] / l }
end

-- Moller-Trumbore ray / triangle. Returns distance and unit normal, or nil.
local function rayTri(o, d, p0, p1, p2)
  local e1, e2 = sub(p1, p0), sub(p2, p0)
  local pv = cross(d, e2)
  local det = dot(e1, pv)
  if det > -1e-10 and det < 1e-10 then return nil end
  local inv = 1 / det
  local tv = sub(o, p0)
  local u = dot(tv, pv) * inv
  if u < 0 or u > 1 then return nil end
  local qv = cross(tv, e1)
  local w = dot(d, qv) * inv
  if w < 0 or u + w > 1 then return nil end
  local t = dot(e2, qv) * inv
  if t <= 1e-4 then return nil end
  return t, norm(cross(e1, e2))
end

local function castAll(o, d, maxT, tris)
  local bestT, bestN = maxT, nil
  for i = 1, #tris do
    local tr = tris[i]
    local t, n = rayTri(o, d, tr[1], tr[2], tr[3])
    if t and t < bestT then bestT, bestN = t, n end
  end
  if bestN then return bestT, bestN end
  return nil
end

local function nodePos(cache, cid)
  local p = cache[cid]
  if p == nil then
    local ok, np = pcall(function() return obj:getNodePosition(cid) end)
    if ok and np then p = { np.x, np.y, np.z } else p = false end
    cache[cid] = p
  end
  return p or nil
end

-- Triangles whose centre lies within 'radius' of the eye (positions relative to the vehicle object, world axes).
local function gatherTriangles(eye, radius)
  local tris = {}
  local okT, list = pcall(function() return v.data.triangles end)
  if not okT or type(list) ~= 'table' then return tris end
  local cache = {}
  local r2 = radius * radius
  for _, t in pairs(list) do
    if type(t) == 'table' and t.id1 and t.id2 and t.id3 then
      local p0, p1, p2 = nodePos(cache, t.id1), nodePos(cache, t.id2), nodePos(cache, t.id3)
      if p0 and p1 and p2 then
        local cx = (p0[1] + p1[1] + p2[1]) / 3 - eye[1]
        local cy = (p0[2] + p1[2] + p2[2]) / 3 - eye[2]
        local cz = (p0[3] + p1[3] + p2[3]) / 3 - eye[3]
        if cx * cx + cy * cy + cz * cz < r2 then tris[#tris + 1] = { p0, p1, p2 } end
      end
    end
  end
  return tris
end

-- Vehicle basis in world axes: direction vectors when available, ref nodes otherwise.
local function basis()
  local f, u
  pcall(function()
    local a, b = obj:getDirectionVector(), obj:getDirectionVectorUp()
    if a and b then f, u = { a.x, a.y, a.z }, { b.x, b.y, b.z } end
  end)
  if not f then
    pcall(function()
      local rn = v.data.refNodes[0]
      local cache = {}
      local ref, back, up = nodePos(cache, rn.ref), nodePos(cache, rn.back), nodePos(cache, rn.up)
      if ref and back and up then f, u = sub(ref, back), sub(up, ref) end
    end)
  end
  if not f then return nil end
  local fwd = norm(f)
  local right = norm(cross(fwd, u))   -- same convention as GE: right = forward x up
  local up = norm(cross(right, fwd))
  return fwd, right, up
end

local function fmtVec(a) return string.format('{%.5f,%.5f,%.5f}', a[1], a[2], a[3]) end

-- 1.0: the windshield from the car's own jbeam. Every official BeamNG vehicle puts the beams around its windshield
-- (A-pillars, roof front, cowl) in the deform group "windshield_break"; the glass sits on that frame. A plane through
-- those nodes (robust: best triplet + inliers, then least squares) is the glass, and the outermost frame nodes give its
-- four corners. Returns a result in world axes relative to the vehicle position, or nil + reason.
local function isWindshieldGroup(dg)
  if type(dg) == 'string' then return dg:lower():find('windshield', 1, true) ~= nil end
  if type(dg) == 'table' then
    for _, g in pairs(dg) do
      if type(g) == 'string' and g:lower():find('windshield', 1, true) then return true end
    end
  end
  return false
end

local function frameWindshield(fwd, right, up)
  local okB, beams = pcall(function() return v.data.beams end)
  local okN, nodes = pcall(function() return v.data.nodes end)
  if not okB or type(beams) ~= 'table' then return nil, 'no beam data' end
  if not okN or type(nodes) ~= 'table' then nodes = {} end
  local cache, set, pts = {}, {}, {}
  for _, b in pairs(beams) do
    if type(b) == 'table' and isWindshieldGroup(b.deformGroup) then
      for _, id in ipairs({ b.id1, b.id2 }) do
        local nd = nodes[id]
        local cid = (type(nd) == 'table' and nd.cid) or id
        if cid ~= nil and not set[cid] then
          set[cid] = true
          local p = nodePos(cache, cid)
          if p then pts[#pts + 1] = p end
        end
      end
    end
  end
  if #pts < 4 then return nil, 'no windshield frame in the jbeam' end
  if #pts > 60 then return nil, 'windshield frame too large' end

  -- A windshield is left-right symmetric, so its plane contains the car's right axis: search lines through pairs of
  -- frame nodes in the (forward, up) section. The tolerance (12 cm) covers the curve of the glass (a D15's cowl centre
  -- sits 12 cm ahead of its corners) but not the frame's other nodes (second roof row, lower firewall, door frames).
  local TOL = 0.12
  local P2 = {}
  for m = 1, #pts do P2[m] = { dot(pts[m], fwd), dot(pts[m], up) } end
  local bestCount, bestNf, bestNu, bestI = 0, nil, nil, nil
  for i = 1, #pts - 1 do
    for j = i + 1, #pts do
      local dx, dy = P2[j][1] - P2[i][1], P2[j][2] - P2[i][2]
      local l = math.sqrt(dx * dx + dy * dy)
      if l > 0.15 then
        local nf, nu = dy / l, -dx / l
        if nf < 0 then nf, nu = -nf, -nu end
        if nf > 0.3 then
          local count = 0
          for m = 1, #pts do
            if math.abs((P2[m][1] - P2[i][1]) * nf + (P2[m][2] - P2[i][2]) * nu) < TOL then count = count + 1 end
          end
          if count > bestCount then bestCount, bestNf, bestNu, bestI = count, nf, nu, i end
        end
      end
    end
  end
  if not bestNf or bestCount < 4 then return nil, 'windshield frame is not planar' end

  -- inliers, then a total-least-squares line through them in the (forward, up) section
  local inl, cen = {}, { 0, 0, 0 }
  local mf, mu = 0, 0
  for m = 1, #pts do
    if math.abs((P2[m][1] - P2[bestI][1]) * bestNf + (P2[m][2] - P2[bestI][2]) * bestNu) < TOL then
      inl[#inl + 1] = pts[m]
      cen = add(cen, pts[m])
      mf, mu = mf + P2[m][1], mu + P2[m][2]
    end
  end
  cen = { cen[1] / #inl, cen[2] / #inl, cen[3] / #inl }
  mf, mu = mf / #inl, mu / #inl
  local sff, sfu, suu = 0, 0, 0
  for m = 1, #pts do
    if math.abs((P2[m][1] - P2[bestI][1]) * bestNf + (P2[m][2] - P2[bestI][2]) * bestNu) < TOL then
      local a, b = P2[m][1] - mf, P2[m][2] - mu
      sff, sfu, suu = sff + a * a, sfu + a * b, suu + b * b
    end
  end
  local ang = 0.5 * math.atan2(2 * sfu, sff - suu)              -- direction of the glass in the section
  local nf, nu = -math.sin(ang), math.cos(ang)                  -- its normal
  if nf < 0 then nf, nu = -nf, -nu end
  if nf < 0.3 then nf, nu = bestNf, bestNu end
  local n = norm(add({ fwd[1] * nf, fwd[2] * nf, fwd[3] * nf }, up, nu))

  -- glass axes and the four corners (outermost frame nodes along the diagonals)
  local gR = norm(sub(right, { n[1] * dot(right, n), n[2] * dot(right, n), n[3] * dot(right, n) }))
  local gU = norm(cross(n, gR))
  if dot(gU, up) < 0 then gU = { -gU[1], -gU[2], -gU[3] } end
  local bl, br, trc, tl = nil, nil, nil, nil
  local sBL, sBR, sTR, sTL = 1e9, 1e9, -1e9, -1e9
  for m = 1, #inl do
    local d = sub(inl[m], cen)
    local a, b = dot(d, gR), dot(d, gU)
    if a + b < sBL then sBL, bl = a + b, { a, b } end
    if b - a < sBR then sBR, br = b - a, { a, b } end
    if a + b > sTR then sTR, trc = a + b, { a, b } end
    if b - a > sTL then sTL, tl = b - a, { a, b } end
  end
  local midA = (bl[1] + br[1] + trc[1] + tl[1]) * 0.25
  local midB = (bl[2] + br[2] + trc[2] + tl[2]) * 0.25
  local hw = math.max(math.abs(bl[1] - midA), math.abs(br[1] - midA), math.abs(trc[1] - midA), math.abs(tl[1] - midA))
  local hh = math.max(math.abs(bl[2] - midB), math.abs(br[2] - midB), math.abs(trc[2] - midB), math.abs(tl[2] - midB))
  if hw < 0.2 or hh < 0.1 then return nil, 'windshield frame too small' end
  local c = add(add(cen, gR, midA), gU, midB)
  local function q(p) return { (p[1] - midA) / hw, (p[2] - midB) / hh } end

  -- glass-space coordinates of every frame node on the glass (metres from the glass centre c)
  local A, B, D = {}, {}, {}
  for m = 1, #inl do
    local d = sub(inl[m], c)
    A[m], B[m], D[m] = dot(d, gR), dot(d, gU), dot(d, n)
  end

  -- 1.0 outline: convex hull of ALL frame nodes (monotone chain), so the mask follows the real shape of the glass
  -- (pillar bulges, rounded corners) instead of a four-corner quad; at most 12 corners, the least important dropped.
  local idx = {}
  for m = 1, #inl do idx[m] = m end
  table.sort(idx, function(i, j) if A[i] ~= A[j] then return A[i] < A[j] end return B[i] < B[j] end)
  local function crossO(o, i, j) return (A[i] - A[o]) * (B[j] - B[o]) - (B[i] - B[o]) * (A[j] - A[o]) end
  local hull = {}
  for _, i in ipairs(idx) do
    while #hull >= 2 and crossO(hull[#hull - 1], hull[#hull], i) <= 1e-6 do hull[#hull] = nil end
    hull[#hull + 1] = i
  end
  local lower = #hull + 1
  for k = #idx - 1, 1, -1 do
    local i = idx[k]
    while #hull >= lower and crossO(hull[#hull - 1], hull[#hull], i) <= 1e-6 do hull[#hull] = nil end
    hull[#hull + 1] = i
  end
  hull[#hull] = nil                                            -- last point repeats the first
  while #hull > 12 do                                          -- drop the corner that spans the smallest triangle
    local best, bestArea = 1, 1e9
    for k = 1, #hull do
      local p, s, nx = hull[(k - 2) % #hull + 1], hull[k], hull[k % #hull + 1]
      local area = math.abs(crossO(p, s, nx))
      if area < bestArea then best, bestArea = k, area end
    end
    table.remove(hull, best)
  end
  local poly = {}
  if #hull >= 3 then
    for _, i in ipairs(hull) do
      poly[#poly + 1] = A[i] / hw
      poly[#poly + 1] = B[i] / hh
    end
  end

  -- 1.0 curvature: windshields bulge forward in the middle (a D15's cowl centre sits ~12 cm ahead of its corners).
  -- Offset along the normal d = k0 + k1*b + (k2 + k3*b)*a^2, least squares over the frame nodes (4x4 normal equations).
  local curv = { 0, 0, 0, 0 }
  if #inl >= 6 then
    local M4, R4 = {}, { 0, 0, 0, 0 }
    for r = 1, 4 do M4[r] = { 0, 0, 0, 0 } end
    for m = 1, #inl do
      local a2 = A[m] * A[m]
      local f = { 1, B[m], a2, B[m] * a2 }
      for r = 1, 4 do
        R4[r] = R4[r] + f[r] * D[m]
        for s = 1, 4 do M4[r][s] = M4[r][s] + f[r] * f[s] end
      end
    end
    for r = 1, 4 do M4[r][r] = M4[r][r] + 1e-6 end           -- tiny ridge: stays solvable on symmetric frames
    local okSolve = true
    for col = 1, 4 do                                          -- Gauss-Jordan with partial pivoting
      local piv = col
      for r = col + 1, 4 do if math.abs(M4[r][col]) > math.abs(M4[piv][col]) then piv = r end end
      if math.abs(M4[piv][col]) < 1e-12 then okSolve = false break end
      M4[col], M4[piv] = M4[piv], M4[col]
      R4[col], R4[piv] = R4[piv], R4[col]
      for r = 1, 4 do
        if r ~= col then
          local fct = M4[r][col] / M4[col][col]
          for s = col, 4 do M4[r][s] = M4[r][s] - fct * M4[col][s] end
          R4[r] = R4[r] - fct * R4[col]
        end
      end
    end
    if okSolve then
      for r = 1, 4 do curv[r] = R4[r] / M4[r][r] end
      -- sanity: a windshield never bends more than ~25 cm over its half width
      local edge = math.abs(curv[3] + math.abs(curv[4]) * hh) * hw * hw
      if edge > 0.25 or curv[1] ~= curv[1] then curv = { 0, 0, 0, 0 } end
    end
  end

  return { c = c, n = n, r = gR, u = gU, hw = hw, hh = hh, hits = #inl, tris = #pts, top = true,
           quad = { q(bl), q(br), q(trc), q(tl) }, poly = poly, curv = curv }
end

local function report(vid, res)
  local cmd
  if res then
    local quad = 'nil'
    if res.quad then
      local qd = res.quad
      quad = string.format('{%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f}', qd[1][1], qd[1][2], qd[2][1], qd[2][2], qd[3][1], qd[3][2], qd[4][1], qd[4][2])
    end
    local function list(t)
      if type(t) ~= 'table' or #t == 0 then return 'nil' end
      local p = {}
      for i = 1, #t do p[i] = string.format('%.4f', t[i]) end
      return '{' .. table.concat(p, ',') .. '}'
    end
    cmd = string.format('extensions.rainPuddles.onWindshieldProbe(%d,{ok=true,c=%s,n=%s,r=%s,u=%s,hw=%.4f,hh=%.4f,hits=%d,tris=%d,top=%s,frame=%s,quad=%s,poly=%s,curv=%s})',
      vid, fmtVec(res.c), fmtVec(res.n), fmtVec(res.r), fmtVec(res.u), res.hw, res.hh, res.hits, res.tris, res.top and 'true' or 'false',
      res.quad and 'true' or 'false', quad, list(res.poly), list(res.curv))
  else
    cmd = string.format('extensions.rainPuddles.onWindshieldProbe(%d,{ok=false,note=%q})', vid, M.lastNote or 'failed')
  end
  pcall(function() obj:queueGameEngineLua(cmd) end)
end

-- ex, ey, ez: the driver's eye (camera) position relative to the vehicle object position, world axes.
-- frameOnly = 1 (1.0): the camera is outside the car, so only the jbeam frame may be used (no eye for the ray probe).
M.run = function(ex, ey, ez, vid, frameOnly)
  vid = tonumber(vid) or 0
  local onlyFrame = tonumber(frameOnly) == 1
  local ok, res = pcall(function()
    local eye = { tonumber(ex) or 0, tonumber(ey) or 0, tonumber(ez) or 0 }
    local fwd, right, up = basis()
    if not fwd then M.lastNote = 'no vehicle basis' return nil end
    local function loc(a) return { dot(a, right), dot(a, fwd), dot(a, up) } end

    -- 1.0: the jbeam windshield frame first (exact and independent of the camera); the ray probe below is the
    -- fallback for cars without a "windshield_break" deform group
    local fr, why = frameWindshield(fwd, right, up)
    if fr then
      M.lastNote = 'ok (jbeam frame)'
      return { c = loc(fr.c), n = loc(fr.n), r = loc(fr.r), u = loc(fr.u), hw = fr.hw, hh = fr.hh,
               hits = fr.hits, tris = fr.tris, top = true, quad = fr.quad, poly = fr.poly, curv = fr.curv }
    end
    M.frameNote = why
    if onlyFrame then
      M.lastNote = 'no jbeam windshield frame (' .. tostring(why) .. '); sit in the car to probe the glass'
      return nil
    end

    local tris = gatherTriangles(eye, 3.0)
    if #tris == 0 then M.lastNote = 'no collision triangles near the seat' return nil end

    local hits = {}
    local central = {}   -- [hit index] = true for the rays straight ahead of the driver
    -- 1. the user's probe (0.8): start 5 cm above the driver's eye and go straight forward until the glass is touched.
    --    That point is where the driver looks through the windshield; the fitted glass must contain it.
    -- Only surfaces that face forward/backward can be glass: roof, dashboard and hood triangles are near horizontal.
    local function glassLike(n) return n and math.abs(dot(n, fwd)) > 0.25 end
    local start = add(eye, up, 0.05)
    local tTop, nTop = castAll(start, fwd, 2.5, tris)
    if tTop and not glassLike(nTop) then tTop = nil end
    if tTop then
      hits[#hits + 1] = add(start, fwd, tTop)
      central[#hits] = true
    end
    -- 2. fan from the same point toward the front (yaw +-48 deg, pitch -30..+20 deg) for the plane and its size
    for iy = -4, 4 do
      for ip = -3, 2 do
        local d = norm(add(add(fwd, right, math.tan(iy * 0.21)), up, math.tan(ip * 0.17)))
        local t, n = castAll(start, d, 2.4, tris)
        if t and t > 0.18 and math.abs(dot(n, d)) > 0.2 and glassLike(n) then
          hits[#hits + 1] = add(start, d, t)
          if math.abs(iy) <= 1 and ip >= 0 and ip <= 1 then central[#hits] = true end
        end
      end
    end
    if #hits < 5 then M.lastNote = string.format('only %d hits in front of the seat', #hits) return nil end

    -- 3. robust plane: best triplet whose normal faces forward (not roof / dashboard), most inliers within 5 cm.
    --    Candidates are an even subset of the hits (spread over the whole fan) to keep this a few milliseconds.
    local cand = {}
    local stepC = math.max(1, math.floor(#hits / 22))
    for m = 1, #hits, stepC do cand[#cand + 1] = hits[m] end
    local nH = #cand
    local bestCount, bestN, bestP = 0, nil, nil
    for i = 1, nH - 2 do
      for j = i + 1, nH - 1 do
        for k = j + 1, nH do
          local n = cross(sub(cand[j], cand[i]), sub(cand[k], cand[i]))
          if len(n) > 1e-4 then
            n = norm(n)
            if dot(n, fwd) < 0 then n = { -n[1], -n[2], -n[3] } end
            if dot(n, fwd) > 0.25 and dot(n, up) > -0.2 then
              local count = 0
              for m = 1, #hits do
                if math.abs(dot(sub(hits[m], cand[i]), n)) < 0.05 then count = count + 1 end
              end
              if count > bestCount then bestCount, bestN, bestP = count, n, cand[i] end
            end
          end
        end
      end
    end
    if not bestN or bestCount < 5 then M.lastNote = 'no forward-facing glass plane found' return nil end

    -- 4. inliers + least-squares refinement, re-selecting the inliers with a tighter tolerance each pass, so hits on
    --    the roof or dashboard right at the edge of the glass (within the loose 5 cm) cannot tilt the plane
    local function collect(pt, n, tol)
      local inl, cen, cIn = {}, { 0, 0, 0 }, 0
      for m = 1, #hits do
        if math.abs(dot(sub(hits[m], pt), n)) < tol then
          inl[#inl + 1] = hits[m]
          cen = add(cen, hits[m])
          if central[m] then cIn = cIn + 1 end
        end
      end
      if #inl > 0 then cen = { cen[1] / #inl, cen[2] / #inl, cen[3] / #inl } end
      return inl, cen, cIn
    end
    local function refine(inl, cen, n)     -- one Gauss-Newton step of h = a*s + b*t in the plane's own frame
      local tR = norm(cross(n, up))
      local tU = cross(tR, n)
      local saa, sab, sbb, sah, sbh = 0, 0, 0, 0, 0
      for m = 1, #inl do
        local d = sub(inl[m], cen)
        local a, b, h = dot(d, tR), dot(d, tU), dot(d, n)
        saa, sab, sbb, sah, sbh = saa + a * a, sab + a * b, sbb + b * b, sah + a * h, sbh + b * h
      end
      local det = saa * sbb - sab * sab
      if math.abs(det) < 1e-9 then return n end
      local ka = (sah * sbb - sbh * sab) / det
      local kb = (sbh * saa - sah * sab) / det
      return norm(sub(n, add({ tR[1] * ka, tR[2] * ka, tR[3] * ka }, tU, kb)))
    end
    local inl, cen, centralIn = collect(bestP, bestN, 0.05)
    for _, tol in ipairs({ 0.05, 0.035, 0.025, 0.02 }) do
      if #inl < 4 then break end
      bestN = refine(inl, cen, bestN)
      inl, cen, centralIn = collect(cen, bestN, tol)
    end
    -- the glass must be what the driver looks through: the straight-ahead hits have to land on it
    if #inl < 8 or centralIn < 1 then
      M.lastNote = string.format('no glass straight ahead (%d plane hits, %d ahead)', #inl, centralIn)
      return nil
    end
    local gR = norm(sub(right, { bestN[1] * dot(right, bestN), bestN[2] * dot(right, bestN), bestN[3] * dot(right, bestN) }))
    local gU = norm(cross(bestN, gR))
    if dot(gU, up) < 0 then gU = { -gU[1], -gU[2], -gU[3] } end
    local minR, maxR, minU, maxU = 1e9, -1e9, 1e9, -1e9
    for m = 1, #inl do
      local d = sub(inl[m], cen)
      local a, b = dot(d, gR), dot(d, gU)
      minR, maxR = math.min(minR, a), math.max(maxR, a)
      minU, maxU = math.min(minU, b), math.max(maxU, b)
    end
    local c = add(add(cen, gR, (minR + maxR) * 0.5), gU, (minU + maxU) * 0.5)
    -- the fan only samples part of the glass: grow the extents a little (the shader's depth mask trims them)
    -- (the fan reaches ~75 % of the glass height: roof/dash hits are not glass) - the depth mask clips to the real opening
    local hw = math.max((maxR - minR) * 0.5 * 1.20 + 0.06, 0.25)
    local hh = math.max((maxU - minU) * 0.5 * 1.35 + 0.06, 0.12)

    -- 5. to vehicle-local coordinates (x right, y forward, z up)
    local function loc(a) return { dot(a, right), dot(a, fwd), dot(a, up) } end
    M.lastNote = 'ok'
    return { c = loc(c), n = loc(bestN), r = loc(gR), u = loc(gU), hw = hw, hh = hh, hits = #inl, tris = #tris, top = tTop ~= nil }
  end)
  if not ok then M.lastNote = 'error: ' .. tostring(res) res = nil end
  report(vid, res)
end

-- 0.9: tread speed of every wheel (|angular velocity| x radius, m/s), for tyre spray and puddle wakes: a spinning tyre
-- throws water and churns a puddle even when the car barely moves. Falls back to the average wheel speed.
M.reportWheels = function(vid)
  local parts = {}
  pcall(function()
    local list = wheels and (wheels.wheelRotators or wheels.wheels)
    if type(list) == 'table' then
      for i = 0, 15 do
        local w = list[i]
        if type(w) == 'table' then
          local av = tonumber(w.angularVelocity)
          local r = tonumber(w.radius) or tonumber(w.hubRadius)
          if av and r then parts[#parts + 1] = string.format('[%d]=%.3f', i, math.abs(av) * r) end
        end
      end
    end
  end)
  if #parts == 0 then
    pcall(function()
      local ws = electrics and electrics.values and tonumber(electrics.values.wheelspeed)
      if ws then
        for i = 0, 5 do parts[#parts + 1] = string.format('[%d]=%.3f', i, math.abs(ws)) end
      end
    end)
  end
  pcall(function()
    obj:queueGameEngineLua(string.format('extensions.rainPuddles.onWheelSpin(%d,{%s})', tonumber(vid) or 0, table.concat(parts, ',')))
  end)
  -- 1.0: the car's wiper stalk ("wipers" electrics value, used by the stalk prop of e.g. the ETK 800, ETK K-series,
  -- Midsize, Percheron, SBR). Vanilla BeamNG never sets it, so it is only reported once something (a mod, a
  -- controller) does; the windshield layer then follows the stalk instead of its automatic wipers.
  pcall(function()
    local wv = electrics and electrics.values and electrics.values.wipers
    if wv ~= nil then
      obj:queueGameEngineLua(string.format('extensions.rainPuddles.onWiperStalk(%d,%.3f)', tonumber(vid) or 0, tonumber(wv) or 0))
    end
  end)
end

return M
