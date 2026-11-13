import RainPuddlesScreen from "./views/RainPuddlesScreen.vue"
import { ROUTE_NAME, ROUTE_SOURCE_ID } from "./shared/constants.js"

export { ROUTE_SOURCE_ID }

// Side-panel settings screen. The rest of the screen stays transparent so the effect can be tuned live.
export const routeRecords = [
  {
    path: "/menu/rain-puddles",
    name: ROUTE_NAME,
    component: RainPuddlesScreen,
    meta: {
      luaRoute: {
        title: "Rain Puddles & Droplets",
        backTarget: "menu",
        scopeTree: { "rain-puddles-route": {} },
      },
    },
  },
]
