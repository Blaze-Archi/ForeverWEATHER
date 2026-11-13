// Every control below is read by the shader or by the Lua modules (same set as the v0.5 app, plus the 0.6 additions).
// Slider: { k: setting key, l: label, a: min, b: max, st: step, d: decimals, hint?: tooltip }

export const TOGGLES = [
  { k: "enabled", l: "Mod" },
  { k: "wetGround", l: "Wet ground" },
  { k: "puddles", l: "Puddles" },
  { k: "droplets", l: "Body drops" },
  { k: "windshield", l: "Windshield" },
  { k: "lens", l: "Lens drops" },
  { k: "splashes", l: "Tyre spray" },
  { k: "rainStreaks", l: "Falling rain" },
]

// 1.0 one-click looks (values live in Lua: extensions.rainPuddles.applyPreset)
export const PRESETS = [
  { k: "damp", l: "Damp" },
  { k: "wet", l: "Wet" },
  { k: "storm", l: "Storm" },
  { k: "flooded", l: "Flooded" },
]

// 1.0 hydroplaning (node-based, see lua/vehicle/extensions/rainPuddlesHydroVeh.lua)
export const HYDRO_MODES = [
  { v: 0, l: "Off" },
  { v: 1, l: "Arcade" },
  { v: 2, l: "Simcade" },
  { v: 3, l: "Sim" },
]

export const REFLECTION_MODES = [
  { v: 0, l: "Auto (the mod's own film, smooth)" },
  { v: 1, l: "Native PBR + SSR (changes road materials)" },
  { v: 2, l: "Own screen-space trace only" },
]

// What a reflection shows when the screen-space trace finds nothing on screen (0.6.2)
export const FALLBACK_MODES = [
  { v: 0, l: "Visible sky + screen edges (recommended)" },
  { v: 1, l: "Ambient sky colour only" },
  { v: 2, l: "Nothing (real reflections only)" },
  { v: 3, l: "Surroundings: the real scene above (heavier)" },
]

export const SSR_QUALITIES = [
  { v: 0, l: "Keep game setting" },
  { v: 1, l: "Low" },
  { v: 2, l: "Medium" },
  { v: 3, l: "High" },
]

export const DEBUG_VIEWS = [
  { v: 0, l: "Off" }, { v: 1, l: "World grid" }, { v: 2, l: "Normals" }, { v: 3, l: "Puddle field" },
  { v: 4, l: "Distance rings" }, { v: 5, l: "Vehicle shell" }, { v: 6, l: "Own trace confidence" },
  { v: 7, l: "Reflection fallback (what misses show)" }, { v: 8, l: "Windshield (cyan glass, yellow just wiped, white drops)" }, { v: 9, l: "Tyre spray (cyan = water at a tyre, orange = spray)" },
  { v: 10, l: "Build check (stripes = new shader)" }, { v: 11, l: "Vehicle mask truth (green road, red body)" },
  { v: 12, l: "Mask inputs RGB = height / roughness / N.z" }, { v: 13, l: "Own trace outcome" },
  { v: 14, l: "Own trace depth units" }, { v: 15, l: "Droplet force field (hue = direction)" },
  { v: 16, l: "Windshield depth test (red in front of the glass, green beyond)" },
  { v: 17, l: "Wiper model (swept area per blade, red = never wiped)" },
  { v: 18, l: "Surroundings capture (reflection fallback)" },
  { v: 19, l: "Falling rain only (white streaks, blue splashes)" },
]

export const SLIDERS = {
  general: [
    { k: "rain", l: "Rain amount", a: 0, b: 1, st: 0.01, d: 2 },
  ],

  // ---- global wet ground ----
  groundPbr: [
    { k: "roadWetness", l: "Wetness", a: 0, b: 1, st: 0.01, d: 2, hint: "How wet the whole road gets for the current rain amount (native and own film, darkening)." },
    { k: "roadRoughness", l: "Roughness when wet (1 = dry, low = mirror)", a: 0.05, b: 1, st: 0.01, d: 2, hint: "Wet roughness as a fraction of the dry roughness. Raise it so the road stops looking like a mirror. Written into the road materials (native) and used by the own film." },
    { k: "roadDarkening", l: "Darkening", a: 0, b: 1, st: 0.01, d: 2 },
    { k: "roadNormal", l: "Normal detail", a: 0, b: 2, st: 0.01, d: 2, hint: "How much of the road's own bumps show through the film (own film)." },
    { k: "roadVariation", l: "Patchiness", a: 0, b: 1, st: 0.01, d: 2, hint: "0 = uniformly wet, 1 = strongly patchy. Uses the ground's own pattern, not the puddles'." },
    { k: "roadPatchSize", l: "Patch size (m)", a: 4, b: 120, st: 1, d: 0 },
    { k: "roadMaxDistance", l: "Distance (m)", a: 30, b: 600, st: 5, d: 0, hint: "How far from the camera the wet ground is drawn by this mod (the native film is not limited)." },
    { k: "tireMarkGloss", l: "Tyre-mark gloss", a: 0, b: 1, st: 0.01, d: 2 },
  ],
  // work with both reflection engines
  groundReflBoth: [
    { k: "roadReflection", l: "Reflection strength", a: 0, b: 1, st: 0.01, d: 2, hint: "How reflective the wet road gets. BeamNG's own reflections: how much glossier the road materials become. Own trace: the reflectance." },
    { k: "roadFlood", l: "Puddle-like at max rain", a: 0, b: 1, st: 0.01, d: 2, hint: "As the ground gets wetter it turns into the puddle look: 1 = exactly the puddle settings at full rain, 0 = always wet asphalt." },
    { k: "lightStreaks", l: "Light streaks", a: 0, b: 1, st: 0.01, d: 2, hint: "Vertical streaks of lights in wet-road reflections (mod's trace)." },
  ],
  // own trace only
  groundRefl: [
    { k: "roadSkyReflection", l: "Fallback brightness", a: 0, b: 3, st: 0.05, d: 2, hint: "Brightness of what a missed reflection shows (see 'When the reflection misses')." },
    { k: "roadReflectionBlur", l: "Reflection blur", a: 0, b: 1, st: 0.01, d: 2 },
    { k: "roadSsrSteps", l: "Trace steps", a: 8, b: 48, st: 1, d: 0 },
    { k: "roadSsrThickness", l: "Trace thickness (m)", a: 0.05, b: 2, st: 0.01, d: 2 },
  ],

  // ---- puddles ----
  puddlePbr: [
    { k: "puddleCoverage", l: "Coverage", a: 0, b: 0.85, st: 0.01, d: 2 },
    { k: "puddleSize", l: "Size", a: 0, b: 1, st: 0.01, d: 2 },
    { k: "puddleSoftness", l: "Edge softness", a: 0.005, b: 0.2, st: 0.005, d: 3 },
    { k: "tileSize", l: "Pattern size (m)", a: 6, b: 120, st: 1, d: 0 },
    { k: "puddleStrength", l: "Darkening", a: 0, b: 1, st: 0.01, d: 2 },
    { k: "puddleRoughness", l: "Water roughness (0 = mirror)", a: 0, b: 1, st: 0.01, d: 2 },
    { k: "puddleNormal", l: "Normal detail", a: 0, b: 2, st: 0.01, d: 2 },
    { k: "puddleRipple", l: "Rain ripples", a: 0, b: 2, st: 0.05, d: 2, hint: "0.3-style rain rings, inside puddles only." },
    { k: "maxDistance", l: "Distance (m)", a: 30, b: 400, st: 5, d: 0, hint: "How far from the camera puddles are drawn." },
    { k: "vehMaskHeight", l: "Keep off cars: mask height (m)", a: 0.03, b: 0.8, st: 0.01, d: 2, hint: "Inside a car's box, anything this far above the road counts as the car (no puddles or wet ground on it). Lower it if puddles still show on low bodywork, raise it if a dry patch appears around the car." },
  ],
  puddleRefl: [
    { k: "puddleReflection", l: "Reflectivity (1 = mirror)", a: 0, b: 1, st: 0.01, d: 2, hint: "0 = physical water (dark up close, mirror toward the horizon), 1 = mirror at every angle." },
    { k: "skyReflection", l: "Fallback brightness", a: 0, b: 3, st: 0.05, d: 2, hint: "Brightness of what a missed reflection shows (see 'When the reflection misses')." },
    { k: "reflectionBlur", l: "Reflection blur", a: 0, b: 1, st: 0.01, d: 2 },
    { k: "ssrSteps", l: "Trace steps", a: 8, b: 48, st: 1, d: 0 },
    { k: "ssrThickness", l: "Trace thickness (m)", a: 0.05, b: 2, st: 0.01, d: 2 },
  ],
  weather: [
    { k: "wetUpTime", l: "Wet-up time (s)", a: 1, b: 300, st: 1, d: 0, hint: "How long the ground takes to get wet when it starts raining. Puddles take about 2.5x longer to fill." },
    { k: "dryTime", l: "Dry-out time (min)", a: 0.2, b: 60, st: 0.1, d: 1, hint: "How long the ground takes to dry after the rain. Puddles last about 1.6x longer." },
  ],
  rainfx: [
    { k: "rainDropSize", l: "Rain droplet size (mm)", a: 0.4, b: 5, st: 0.1, d: 1, hint: "Size of the raindrops. The falling rain, the beads on the cars and the drops on the glass all scale with it. Drizzle about 0.5 mm, rain 1-2 mm, a downpour 3-5 mm." },
    { k: "rainStreakIntensity", l: "Falling rain visibility", a: 0, b: 2, st: 0.01, d: 2 },
    { k: "rainStreakLength", l: "Streak length", a: 0.2, b: 3, st: 0.05, d: 2, hint: "Motion blur of the falling drops (1 = what a camera sees at 1/60 s)." },
  ],
  nativeRain: [
    { k: "precipMaxDrops", l: "Maximum rain particles", a: 0, b: 24000, st: 100, d: 0 },
  ],
  droplets: [
    { k: "dropletDensity", l: "Density", a: 0, b: 1.5, st: 0.01, d: 2 },
    { k: "dropletSize", l: "Bead radius (m)", a: 0.004, b: 0.04, st: 0.001, d: 3, hint: "At 2.5 mm raindrops; scaled by 'Rain droplet size' (Falling rain section)." },
    { k: "dropletRefraction", l: "Refraction", a: -1.5, b: 1.5, st: 0.05, d: 2 },
    { k: "dropletSpeed", l: "Rain-hit / life rate", a: 0.1, b: 4, st: 0.05, d: 2 },
    { k: "dropletRunners", l: "Moving droplets", a: 0, b: 1, st: 0.01, d: 2, hint: "Drops that run backward with the airflow and down the panels with gravity." },
    { k: "dropletTrails", l: "Wet trails", a: 0, b: 1, st: 0.01, d: 2 },
    { k: "dropletAero", l: "Airflow drag", a: 0, b: 3, st: 0.05, d: 2 },
    { k: "dropletSlide", l: "Gravity", a: 0, b: 1, st: 0.01, d: 2 },
    { k: "dropletInertia", l: "Acceleration inertia", a: 0, b: 2, st: 0.05, d: 2 },
    { k: "dropletSheen", l: "Wet film / sheen", a: 0, b: 1, st: 0.01, d: 2 },
    { k: "dropletMaxDistance", l: "Max distance (m)", a: 5, b: 80, st: 1, d: 0 },
  ],
  lens: [
    { k: "lensIntensity", l: "Intensity", a: 0, b: 2, st: 0.01, d: 2 },
    { k: "lensDensity", l: "Maximum density", a: 0, b: 1, st: 0.01, d: 2 },
    { k: "lensSize", l: "Droplet size", a: 0.008, b: 0.06, st: 0.001, d: 3 },
    { k: "lensClearCenter", l: "Clear centre radius", a: 0, b: 0.6, st: 0.01, d: 2 },
    { k: "lensSpeedResponse", l: "Speed sweep", a: 0, b: 3, st: 0.05, d: 2, hint: "How strongly vehicle speed blows droplets toward the edges." },
    { k: "lensRefraction", l: "Refraction", a: 0, b: 2, st: 0.05, d: 2 },
  ],
  windshield: [
    { k: "windshieldDensity", l: "Rain density", a: 0, b: 1.8, st: 0.01, d: 2 },
    { k: "windshieldSize", l: "Bead radius (m)", a: 0.002, b: 0.03, st: 0.001, d: 3, hint: "At 2.5 mm raindrops; scaled by 'Rain droplet size' (Falling rain section)." },
    { k: "wiperSpeed", l: "Wiper speed", a: 0.1, b: 3, st: 0.05, d: 2 },
    { k: "wiperTrail", l: "Wiper trail width", a: 0, b: 1, st: 0.01, d: 2 },
  ],
  spray: [
    { k: "splashIntensity", l: "Spray intensity", a: 0, b: 2, st: 0.01, d: 2 },
    { k: "splashSize", l: "Spray size", a: 0.25, b: 4, st: 0.01, d: 2 },
    { k: "splashSpeedMin", l: "Minimum speed (m/s)", a: 0, b: 40, st: 0.5, d: 1 },
    { k: "splashPuddle", l: "Only on puddles", a: 0, b: 1, st: 0.01, d: 2, hint: "0 = spray from any wet road (more in puddles), 1 = only where a tyre runs through a puddle." },
    { k: "tyreWakes", l: "Tyre wakes in puddles", a: 0, b: 2, st: 0.05, d: 2, hint: "Churned water as wide as the tyre, bow waves and spin rings where tyres roll through puddles." },
  ],
  hydro: [
    { k: "hydroStrength", l: "Water strength", a: 0, b: 2, st: 0.05, d: 2, hint: "Scales how much of the tyres' load the water carries and how hard it drags. 1 = the mode's own values." },
    { k: "hydroTread", l: "Tread depth (mm)", a: 0, b: 12, st: 0.5, d: 1, hint: "For ordinary road tyres (new: 7-8, worn: 2-3). Slicks, semi-slicks, race and off-road tyres use their own depth. Deeper grooves drain more water before the tyre floats." },
  ],
}
