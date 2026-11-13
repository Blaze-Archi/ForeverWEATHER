// Shared state for every Rain Puddles view. Settings live in Lua (lua/ge/extensions/rainPuddles.lua); this module
// mirrors them, sends edits back and polls the state while at least one view is mounted.
//
// Transport (0.6.1). The Vue bridge's `lua.extensions.*` only exposes Lua functions it already knows, so
// `lua.extensions.rainPuddles` is undefined for this mod (0.6.0 failed there). Calls therefore go out as plain engine
// Lua strings, the same mechanism the old AngularJS app used, and the state comes back two ways:
//   - as the return value, when the transport supports callbacks (bngApi.engineLua), and
//   - as the 'RainPuddlesState' / 'RainPuddlesSettings' UI events that Lua triggers (always).
// If the bridge ever does know the extension, that path is used directly.
import { reactive, onMounted, onUnmounted } from "vue"
import { lua as bridgeLua, useBridge } from "@/bridge"
import { useEvents } from "@/services/events"
import { VERSION } from "./constants.js"

const state = reactive({
  s: {},
  diag: {},
  loaded: false,
  error: "",
  transport: "",
  open: { ground: true, puddles: true, weather: false, rainfx: false, droplets: false, lens: false, windshield: false, spray: false, debug: false },
})

let users = 0
let timer = null
let lastEdit = 0
let lastSeen = 0
let firstAsk = 0
const pending = new Map()
let flushTimer = null

// ---- Lua transport ------------------------------------------------------------------------------------------------
let bridgeObj = null
function getBridge() {
  if (bridgeObj) return bridgeObj
  try {
    bridgeObj = typeof useBridge === "function" ? useBridge() || {} : {}
  } catch (e) {
    bridgeObj = {}
  }
  return bridgeObj
}

// The bridge's own proxy, only if it knows this extension (not the case on 0.40).
function knownExtension() {
  try {
    const l = bridgeLua || getBridge().lua
    const ext = l && l.extensions && l.extensions.rainPuddles
    return ext && typeof ext.setSetting === "function" ? ext : null
  } catch (e) {
    return null
  }
}

// Returns a function (code, callback?) that runs engine (GE) Lua, or null.
function engineLuaFn() {
  if (window.bngApi && typeof window.bngApi.engineLua === "function") {
    state.transport = "bngApi.engineLua"
    return (code, cb) => (cb ? window.bngApi.engineLua(code, cb) : window.bngApi.engineLua(code))
  }
  const api = getBridge().api
  if (api && typeof api.engineLua === "function") {
    state.transport = "bridge api.engineLua"
    return (code, cb) => (cb ? api.engineLua(code, cb) : api.engineLua(code))
  }
  if (window.beamng && typeof window.beamng.sendEngineLua === "function") {
    state.transport = "beamng.sendEngineLua (events only)"
    return code => window.beamng.sendEngineLua(code)
  }
  return null
}

function runLua(code, cb) {
  const fn = engineLuaFn()
  if (!fn) {
    state.error = "No Lua transport found in this UI (bngApi / bridge api / beamng.sendEngineLua)"
    return false
  }
  try {
    const r = fn(code, cb)
    if (cb && r && typeof r.then === "function") r.then(cb).catch(() => {})
    return true
  } catch (e) {
    console.warn("[RainPuddles] engine Lua call failed:", code, e)
    return false
  }
}

function luaValue(value) {
  if (typeof value === "boolean") return value ? "true" : "false"
  const n = Number(value)
  return isFinite(n) ? String(n) : null
}

// Calls extensions.rainPuddles.<fn>(...args) with numeric / boolean / plain-string arguments.
function callExt(fn, args = [], cb) {
  const ext = knownExtension()
  if (ext && typeof ext[fn] === "function") {
    try {
      const r = ext[fn](...args)
      if (cb && r && typeof r.then === "function") r.then(cb).catch(() => {})
      state.transport = "bridge lua.extensions"
      return true
    } catch (e) {
      // fall through to the string transport
    }
  }
  const parts = []
  for (const a of args) {
    if (typeof a === "string") parts.push("'" + a.replace(/[^a-zA-Z0-9_.]/g, "") + "'")
    else {
      const v = luaValue(a)
      if (v === null) return false
      parts.push(v)
    }
  }
  return runLua(`extensions.rainPuddles.${fn.replace(/[^a-zA-Z0-9_]/g, "")}(${parts.join(", ")})`, cb)
}

// ---- state ----------------------------------------------------------------------------------------------------------
function applyState(data) {
  if (!data || typeof data !== "object") return
  lastSeen = Date.now()
  if (data.settings && typeof data.settings === "object" && Date.now() - lastEdit > 450) state.s = data.settings
  if (data.diag && typeof data.diag === "object") state.diag = data.diag
  state.loaded = true
  state.error = ""
}

function onSettingsPushed(data) {
  if (data && typeof data === "object") {
    lastSeen = Date.now()
    state.loaded = true
    state.error = ""
    if (Date.now() - lastEdit > 450) state.s = data
  }
}

function refresh() {
  if (!firstAsk) firstAsk = Date.now()
  callExt("requestState", [], applyState)
  const since = Date.now() - (lastSeen || firstAsk)
  if (since > 5000) {
    state.error = state.loaded
      ? "Lost contact with the Lua extension 'rainPuddles'"
      : "No answer from the Lua extension 'rainPuddles' yet (load a level; restart BeamNG after installing the mod)"
  }
}

function flush() {
  flushTimer = null
  for (const [key, value] of pending) callExt("setSetting", [key, value])
  pending.clear()
}

// Slider drags send at most one call per key every 60 ms; the local value updates immediately.
function set(key, value) {
  if (typeof value !== "boolean") {
    value = Number(value)
    if (!isFinite(value)) return
  }
  state.s[key] = value
  lastEdit = Date.now()
  pending.set(key, value)
  if (!flushTimer) flushTimer = setTimeout(flush, 60)
}

export function openSidePanel(routeName) {
  try {
    const l = bridgeLua || getBridge().lua
    const router = l && l.extensions && l.extensions.ui_router
    // 1.0: the Lua router's function is navigate() (it has no push())
    if (router && typeof router.navigate === "function") {
      router.navigate(routeName, undefined) // 2nd argument keeps the bridge's signature check quiet
      return
    }
  } catch (e) {
    // fall through
  }
  callExt("openUI")
}

export function useRainPuddles() {
  const events = useEvents()
  events.on("RainPuddlesState", applyState)
  events.on("RainPuddlesSettings", onSettingsPushed)

  onMounted(() => {
    users++
    refresh()
    if (!timer) timer = setInterval(refresh, 2000)
  })
  onUnmounted(() => {
    events.off("RainPuddlesState", applyState)
    events.off("RainPuddlesSettings", onSettingsPushed)
    users = Math.max(0, users - 1)
    if (users === 0 && timer) {
      clearInterval(timer)
      timer = null
    }
  })

  const wet = () => state.diag?.wet || null

  return {
    state,
    VERSION,
    set,
    refresh,
    toggle: key => { state.open[key] = !state.open[key] },
    save: () => callExt("save"),
    reset: () => {
      callExt("reset")
      lastEdit = 0
      setTimeout(refresh, 300)
    },
    sweep: () => callExt("sweep"),
    applyPreset: name => {
      callExt("applyPreset", [String(name)])
      lastEdit = 0
      setTimeout(refresh, 300)
    },
    rescanWindshield: () => callExt("rescanWindshield"),
    snapWetness: () => callExt("snapWetness"),
    wetnessText: () => {
      const d = state.diag || {}
      if (d.groundWetness === undefined) return "unknown"
      const w = d.weather || {}
      const src = w.following ? `game weather (${w.objects || 0} rain objects)` : "this mod's Rain amount"
      return `Ground ${Math.round(d.groundWetness * 100)}% wet, puddles ${Math.round((d.puddleWater || 0) * 100)}% full, ` +
        `${Math.round((d.flood || 0) * 100)}% puddle-like. Rain from ${src}.`
    },
    roadsText: () => {
      const r = state.diag?.roads
      if (!r) return ""
      if (r.mode === 0) return "Off: puddles on any flat surface"
      if (r.mode === 2) return "No AI road network on this map: puddles kept to grey, non-green surfaces"
      return `${r.segments} road segments near the camera (AI road network, ${r.nodes} nodes)`
    },
    windshieldText: () => {
      const w = state.diag?.windshield
      if (!w) return "unknown"
      const mode = (w.wiperMode && w.wiperMode !== "off"
        ? `; running ${w.wiperMode}${w.wipesPerMin ? ` (${w.wipesPerMin} wipes/min)` : ""}`
        : "; off") + (w.animatedWipers ? "; driving the Animated Wipers mod's blades" : "")
        + (w.wipesNeeded && w.wiperMode && w.wiperMode !== "off" ? ` (the rain needs ${w.wipesNeeded}/min)` : "")
        + (w.rearWiper ? `; rear wiper: ${w.rearWiper}${w.rearWipesPerMin ? `, ${w.rearWipesPerMin} wipes/min` : ""}` : "")
      if (w.source === "mesh") {
        return `the car's own glass mesh ${w.mesh} (${Number(w.width).toFixed(2)} x ${Number(w.height).toFixed(2)} m)` +
          (w.rear ? `, rear glass ${w.rear}` : "") + `; wipers: ${w.wipers || "not measured yet"}${mode}`
      }
      if (w.source === "frame") {
        return `the car's own windshield frame (${w.hits} frame nodes, ${Number(w.width).toFixed(2)} x ${Number(w.height).toFixed(2)} m); ` +
          `wipers: ${w.wipers || "not measured yet"}${mode}`
      }
      if (w.source === "probe") {
        return `real glass found by the probe (${w.hits} hits, ${Number(w.width).toFixed(2)} x ${Number(w.height).toFixed(2)} m)`
      }
      return `estimated from the car's box (${w.note || "no probe result"})`
    },
    selfTest: () => callExt("selfTest", [Number(state.s.debugMode) || 0]),
    versionOk: () => state.diag?.version === VERSION,
    nativeActive: () => state.s.reflectionMode !== 2,
    ownActive: () => state.s.reflectionMode !== 1,
    groundEngineText: () => {
      if (!state.loaded) return "unknown"
      if (state.s.reflectionMode === 2) return "this mod's own trace (mode: own only)"
      if (Number(state.diag?.nativeFilm) > 0.5) return "BeamNG native PBR + SSR (road materials)"
      return "this mod's own trace (native path not active yet)"
    },
    ssrText: () => {
      const w = wet()
      if (!w || !w.ssr) return "unknown (companion module not loaded)"
      if (!w.ssr.supported && !w.ssr.objectPresent) return "not available on this renderer (needs Vulkan or Direct3D 12)"
      if (w.ssr.quality === "Off") return "Off. Pick a quality above, or enable it in Options > Graphics (needs Lighting Quality High/Ultra)"
      return "on, quality " + w.ssr.quality + (w.ssr.raisedByMod ? " (raised by this mod while raining)" : "")
    },
    wetText: () => {
      const w = wet()
      if (!w) return "unknown"
      return w.status + (w.matCount ? ` [${w.okCount} adjusted of ${w.matCount} road materials]` : "")
    },
    lastWetError: () => wet()?.lastError || "",
    lensText: () => {
      const l = state.diag?.lens
      if (!l) return "unknown"
      if (!l.active) return "inactive (switched off, or cockpit view without 'also in cockpit')"
      return `active, speed ${((l.speed || 0) * 3.6).toFixed(0)} km/h, rain on lens ${(l.rain || 0).toFixed(2)}` + (l.sheltered ? ", sheltered" : "")
    },
    boxInfo: () => (Array.isArray(state.diag?.boxInfo) ? state.diag.boxInfo : []),
  }
}
