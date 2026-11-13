/*\
 * Rain Puddles & Droplets - Vue UI entry point (replaces the AngularJS app of v0.5 and earlier).
 * Structure follows BeamNG's "Anna's Toolbox" Vue mod example:
 *   - one button in the shared "Mods" pause tab (recommended for mods) -> settings card
 *   - a standalone route with a side panel, so the scene stays visible while tuning
 * All state stays in lua/ge/extensions/rainPuddles.lua (+ rainPuddlesWet.lua); this UI only calls its public API.
 * Console shortcut to the side panel: extensions.rainPuddles.openUI()
\*/

import { useBridge } from "@/bridge"
import { routeRecords } from "./routes.js"
import { MOD_ROOT, PAUSE_BUTTON_ID, ROUTE_SOURCE_ID } from "./shared/constants.js"

const { lua } = useBridge()

function toLuaRoutes(records) {
  return records.map(record => ({
    name: record.name,
    path: record.path,
    meta: record.meta,
    ...(record.children ? { children: toLuaRoutes(record.children) } : {}),
  }))
}

async function registerRoutes() {
  window.bngRoutes.add([{ path: ROUTE_SOURCE_ID, routes: routeRecords }])
  const result = await lua.extensions.ui_router_routeManager.registerModRoutes(ROUTE_SOURCE_ID, toLuaRoutes(routeRecords))
  if (!result?.success) {
    window.bngRoutes.remove([ROUTE_SOURCE_ID])
    console.error("[RainPuddles] failed to register route", result?.errors)
  }
  return result
}

async function unregisterRoutes() {
  window.bngRoutes.remove([ROUTE_SOURCE_ID])
  await lua.extensions.ui_router_routeManager.unregisterModRoutes(ROUTE_SOURCE_ID, { fallbackRoute: "menu" })
}

export async function onLoad() {
  try {
    await registerRoutes()
  } catch (e) {
    console.error("[RainPuddles] route registration error", e)
  }
  // Shared "Mods" pause tab: Pause menu -> Mods -> Rain Puddles
  await lua.extensions.ui_pause_actions.registerModButton({
    id: PAUSE_BUTTON_ID,
    tabId: "mods",
    label: "Rain Puddles",
    icon: "wrench",
    componentName: `${MOD_ROOT}/views/RainPuddlesCard.vue`,
  })
}

export async function onUnload() {
  await unregisterRoutes()
  await lua.extensions.ui_pause_actions.unregisterModButton(PAUSE_BUTTON_ID)
}
