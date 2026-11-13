-- Rain Puddles <-> "Animated Wipers" bridge (vehicle side, Rain Puddles 1.0).
--
-- Talks only to the public interface the Animated Wipers mod puts on a car: its 'animatedWipers' controller
-- (switchMode(0..3), switchModeR(0/1), wipe()) and the electrics values it publishes (wiperVal = front blade position
-- 0..1, wiperValR = rear blade, wipers = stalk). No part of that mod is copied or shipped. On a car without it this
-- extension finds no controller and does nothing.
--
-- Up:   'start' when the front blades leave the parked position, 'end' with the measured cycle time when they are back,
--       'startR' / 'endR' the same for the rear blade, 'state' (stalk value) and 'rear' (1 = the car has that mod's rear
--       wiper) twice a second -> extensions.rainPuddles.onAnimatedWipers(vid, kind, value)
-- Down: setMode(m) from the Rain Puddles rain sensor (0 off, 1 slow, 2 medium, 3 fast), setRear(0/1), wipe() for one sweep.

local M = {}

local vid = 0
local aw = nil          -- the Animated Wipers controller on this car (nil = not installed / not on this car)
local clock = 0
local lastVal = 0
local cycleAt = nil
local lastValR = 0
local cycleAtR = nil
local beat = 0
local commanded = nil
local commandedR = nil

local function findController()
  if controller and type(controller.getController) == 'function' then
    local ok, c = pcall(controller.getController, 'animatedWipers')
    if ok and type(c) == 'table' and type(c.switchMode) == 'function' then return c end
  end
  return nil
end

local function send(kind, value)
  -- 1.0: a value easing toward 0 ends up as a denormal, which LuaJIT's %f prints as a huge garbage number (seen in game:
  -- the stalk read 7e16 after the wipers were switched off); flushed to 0, NaN too
  local v = tonumber(value) or 0
  if v ~= v or math.abs(v) < 1e-6 then v = 0 end
  v = math.max(-1e6, math.min(1e6, v))
  pcall(function()
    obj:queueGameEngineLua(string.format("if extensions.rainPuddles and extensions.rainPuddles.onAnimatedWipers then extensions.rainPuddles.onAnimatedWipers(%d,'%s',%.4f) end",
      vid, kind, v))
  end)
end

M.start = function(id)
  vid = tonumber(id) or vid
  aw = findController()
  commanded, commandedR = nil, nil
  beat = 1e9                      -- report right away
end

M.setMode = function(m)
  aw = aw or findController()
  if not aw then return end
  m = math.max(0, math.min(3, math.floor(tonumber(m) or 0)))
  if m == commanded then return end
  commanded = m
  pcall(aw.switchMode, m)
end

-- rear wiper on (1) / off (0); nothing happens on a car without that mod's rear wiper
M.setRear = function(on)
  aw = aw or findController()
  if not (aw and type(aw.switchModeR) == 'function') then return end
  on = ((tonumber(on) or 0) > 0.5) and 1 or 0
  if on == commandedR then return end
  commandedR = on
  pcall(aw.switchModeR, on)
end

M.wipe = function()
  aw = aw or findController()
  if aw and type(aw.wipe) == 'function' then pcall(aw.wipe) end
end

M.updateGFX = function(dt)
  if not aw then return end
  dt = tonumber(dt) or 0
  clock = clock + dt
  local ev = electrics and electrics.values or {}
  local v = tonumber(ev.wiperVal) or 0
  if lastVal <= 0 and v > 0 then
    cycleAt = clock
    send('start', dt)             -- value: how long ago (s) within this frame it started, at most one frame
  elseif lastVal > 0 and v <= 0 and cycleAt then
    send('end', clock - cycleAt)
    cycleAt = nil
  end
  lastVal = v
  local vr = tonumber(ev.wiperValR)
  if vr then
    if lastValR <= 0 and vr > 0 then
      cycleAtR = clock
      send('startR', dt)
    elseif lastValR > 0 and vr <= 0 and cycleAtR then
      send('endR', clock - cycleAtR)
      cycleAtR = nil
    end
    lastValR = vr
  end
  beat = beat + dt
  if beat >= 0.5 then
    beat = 0
    send('state', tonumber(ev.wipers) or 0)
    send('rear', vr and 1 or 0)
  end
end

M.onReset = function()
  lastVal, cycleAt = 0, nil
  lastValR, cycleAtR = 0, nil
end

return M
