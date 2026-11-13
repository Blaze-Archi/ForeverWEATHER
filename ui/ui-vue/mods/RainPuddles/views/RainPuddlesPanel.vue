<template>
  <div class="rp-panel">
    <div class="rp-head">
      <span class="rp-title">Rain Puddles &amp; Droplets</span>
      <span class="rp-muted">v{{ VERSION }}</span>
    </div>

    <div v-if="state.error" class="rp-note rp-warn">{{ state.error }}</div>

    <div class="rp-toggles">
      <BngSwitch
        v-for="t in TOGGLES"
        :key="t.k"
        :model-value="!!state.s[t.k]"
        @update:model-value="rp.set(t.k, $event)"
      >
        {{ t.l }}
      </BngSwitch>
    </div>
    <div class="rp-muted">
      UI {{ VERSION }} · Lua
      <b :class="rp.versionOk() ? 'rp-ok' : 'rp-bad'">{{ state.diag.version || "OLD - restart BeamNG" }}</b>
      · Rain {{ Number(state.s.rain || 0).toFixed(2) }}
    </div>

    <div class="rp-sub">Quick look</div>
    <div class="rp-muted">Not sure what to tune? Pick a look: it sets the rain and the whole wet road in one go.</div>
    <div class="rp-actions">
      <BngButton v-for="p in PRESETS" :key="p.k" @click="rp.applyPreset(p.k)">{{ p.l }}</BngButton>
    </div>

    <RpSlider v-for="x in SLIDERS.general" :key="x.k" v-bind="sliderProps(x)" @change="rp.set(x.k, $event)" />
    <BngSwitch :model-value="!!state.s.autoClouds" @update:model-value="rp.set('autoClouds', $event)">
      Cloud the sky over while it rains
    </BngSwitch>

    <!-- ================= GLOBAL WET GROUND ================= -->
    <RpSection title="Wet ground (global)" :open="state.open.ground" @toggle="rp.toggle('ground')">
      <div class="rp-muted">The whole road surface (switch: "Wet ground" above). Nothing here changes the puddles.</div>

      <div class="rp-sub">Surface (PBR)</div>
      <RpSlider v-for="x in SLIDERS.groundPbr" :key="x.k" v-bind="sliderProps(x)" @change="rp.set(x.k, $event)" />

      <div class="rp-sub">Reflections</div>
      <div class="rp-note rp-muted">Ground reflection drawn by: <b>{{ rp.groundEngineText() }}</b></div>
      <RpSlider v-for="x in SLIDERS.groundReflBoth" :key="x.k" v-bind="sliderProps(x)" @change="rp.set(x.k, $event)" />
      <BngSwitch :model-value="!!state.s.stochasticGloss" @update:model-value="rp.set('stochasticGloss', $event)">
        Stochastic glossy reflections (experimental, needs TAA / DLSS / FSR)
      </BngSwitch>
      <RpSelect label="Reflection engine" :value="state.s.reflectionMode" :options="REFLECTION_MODES"
        hint="Auto: the mod draws the wet road itself (no hitches, dry in tunnels). Native: BeamNG's own PBR + SSR on the road materials; they are rewritten a few per frame whenever the wetness changes (that costs frame time), and tunnel roads shine too. Puddles always use the mod's trace."
        @change="rp.set('reflectionMode', $event)" />
      <template v-if="rp.nativeActive()">
        <div class="rp-minor">Native (BeamNG PBR + SSR)</div>
        <BngSwitch :model-value="!!state.s.wetRoadMaterials" @update:model-value="rp.set('wetRoadMaterials', $event)">
          Wet-road materials
        </BngSwitch>
        <RpSelect label="Native SSR quality" :value="state.s.nativeSsrQuality" :options="SSR_QUALITIES"
          hint="Graphics key PostFXSSRQuality. Needs Lighting Quality High/Ultra on Vulkan or Direct3D 12."
          @change="rp.set('nativeSsrQuality', $event)" />
        <BngSwitch :model-value="!!state.s.nativeSsrRestore" @update:model-value="rp.set('nativeSsrRestore', $event)">
          Restore my SSR setting when the rain stops
        </BngSwitch>
        <div class="rp-note rp-muted">
          Native SSR: {{ rp.ssrText() }}<br />
          Wet roads: {{ rp.wetText() }}
          <template v-if="rp.lastWetError()"><br />Last material error: {{ rp.lastWetError() }}</template>
        </div>
        <div class="rp-muted">The native reflection follows "Roughness when wet", "Reflection strength" and "Puddle-like at max rain".</div>
      </template>
      <template v-if="rp.ownActive()">
        <div class="rp-minor">Own trace</div>
        <RpSlider v-for="x in SLIDERS.groundRefl" :key="x.k" v-bind="sliderProps(x)" @change="rp.set(x.k, $event)" />
        <RpSelect label="When the reflection misses" :value="state.s.roadFallback" :options="FALLBACK_MODES"
          hint="What the film shows where the screen-space trace finds nothing on screen (e.g. sky above the top edge)."
          @change="rp.set('roadFallback', $event)" />
      </template>
    </RpSection>

    <!-- ================= PUDDLES ================= -->
    <RpSection title="Puddles" :open="state.open.puddles" @toggle="rp.toggle('puddles')">
      <div class="rp-muted">Standing water only (switch: "Puddles" above). Nothing here changes the wet ground.</div>

      <div class="rp-sub">Surface (PBR)</div>
      <BngSwitch :model-value="!!state.s.puddleRoadsOnly" @update:model-value="rp.set('puddleRoadsOnly', $event)">
        Roads only (no puddles on sand, grass or off the road)
      </BngSwitch>
      <div class="rp-muted">{{ rp.roadsText() }}</div>
      <RpSlider v-for="x in SLIDERS.puddlePbr" :key="x.k" v-bind="sliderProps(x)" @change="rp.set(x.k, $event)" />

      <div class="rp-sub">Reflections</div>
      <div class="rp-muted">Puddles always use this mod's screen-space trace. 'Surroundings' renders a small extra view of the
        scene above the camera (sized by the game's Dynamic Reflections quality), so missed reflections show trees,
        bridges and buildings instead of open sky.</div>
      <RpSlider v-for="x in SLIDERS.puddleRefl" :key="x.k" v-bind="sliderProps(x)" @change="rp.set(x.k, $event)" />
      <RpSelect label="When the reflection misses" :value="state.s.puddleFallback" :options="FALLBACK_MODES"
        hint="What a puddle shows where the screen-space trace finds nothing on screen (e.g. sky above the top edge)."
        @change="rp.set('puddleFallback', $event)" />
    </RpSection>

    <RpSection title="Weather & drying" :open="state.open.weather" @toggle="rp.toggle('weather')">
      <div class="rp-note rp-muted">{{ rp.wetnessText() }}</div>
      <BngSwitch :model-value="!!state.s.followWeather" @update:model-value="rp.set('followWeather', $event)">
        Follow the game's weather (rain amount comes from its rain particles)
      </BngSwitch>
      <BngSwitch :model-value="!!state.s.drySim" @update:model-value="rp.set('drySim', $event)">
        Wet-up and drying over time
      </BngSwitch>
      <RpSlider v-for="x in SLIDERS.weather" :key="x.k" v-bind="sliderProps(x)" @change="rp.set(x.k, $event)" />
      <BngButton @click="rp.snapWetness()">Skip to the current rain (wet / dry now)</BngButton>
    </RpSection>

    <RpSection title="Falling rain" :open="state.open.rainfx" @toggle="rp.toggle('rainfx')">
      <div class="rp-muted">This mod's own rain, drawn on the graphics card: streaks with real depth that lean with the wind
        and rush at you when driving, and no rain under roofs, bridges or in tunnels. Switch it with
        'Falling rain' at the top.</div>
      <RpSlider v-for="x in SLIDERS.rainfx" :key="x.k" v-bind="sliderProps(x)" @change="rp.set(x.k, $event)" />
      <BngSwitch :model-value="!!state.s.precipitation" @update:model-value="rp.set('precipitation', $event)">
        BeamNG's particle rain too (heavy on the CPU)
      </BngSwitch>
      <template v-if="state.s.precipitation">
        <RpSlider v-for="x in SLIDERS.nativeRain" :key="x.k" v-bind="sliderProps(x)" @change="rp.set(x.k, $event)" />
      </template>
    </RpSection>

    <RpSection title="Vehicle droplets" :open="state.open.droplets" @toggle="rp.toggle('droplets')">
      <RpSlider v-for="x in SLIDERS.droplets" :key="x.k" v-bind="sliderProps(x)" @change="rp.set(x.k, $event)" />
    </RpSection>

    <RpSection title="Camera lens droplets" :open="state.open.lens" @toggle="rp.toggle('lens')">
      <div class="rp-muted">Swept from the centre to the screen edges, faster with speed. Off in cockpit views by default (the windshield layer handles those).</div>
      <RpSlider v-for="x in SLIDERS.lens" :key="x.k" v-bind="sliderProps(x)" @change="rp.set(x.k, $event)" />
      <BngSwitch :model-value="!!state.s.lensInCockpit" @update:model-value="rp.set('lensInCockpit', $event)">
        Also in cockpit views
      </BngSwitch>
      <div class="rp-note rp-muted">Lens: {{ rp.lensText() }}</div>
    </RpSection>

    <RpSection title="Windshield & wipers" :open="state.open.windshield" @toggle="rp.toggle('windshield')">
      <RpSlider v-for="x in SLIDERS.windshield" :key="x.k" v-bind="sliderProps(x)" @change="rp.set(x.k, $event)" />
      <BngSwitch :model-value="!!state.s.wiperAuto" @update:model-value="rp.set('wiperAuto', $event)">
        Automatic wipers (rain sensor)
      </BngSwitch>
      <BngSwitch :model-value="!!state.s.windshieldOutside" @update:model-value="rp.set('windshieldOutside', $event)">
        Also when looking at your car from outside
      </BngSwitch>
      <BngSwitch :model-value="!!state.s.rearGlass" @update:model-value="rp.set('rearGlass', $event)">
        Drops on the rear / hatch glass too
      </BngSwitch>
      <BngSwitch :model-value="!!state.s.rearWiper" @update:model-value="rp.set('rearWiper', $event)">
        Rear wiper (cars that have one)
      </BngSwitch>
      <BngSwitch :model-value="!!state.s.sideGlass" @update:model-value="rp.set('sideGlass', $event)">
        Drops on the side windows too
      </BngSwitch>
      <div class="rp-muted">Shown in in-car cameras and, on your own car, from outside (once its windshield frame is read).
        Drops bead, run down when parked and are blown up the glass at speed, like the body drops (same airflow /
        gravity / inertia sliders). The wipers start by themselves when rain lands on the glass and go intermittent,
        normal or fast with the rain and your speed; 'Wiper speed' scales all of them. The glass clears where the car's
        own wipers sweep (read from its wiper mesh); no extra blades are drawn. With the "Animated Wipers" mod installed,
        its blades are switched by the rain sensor and the glass clears exactly as they move (switch them by hand and
        Rain Puddles follows you instead). The glass outline comes from the car's own glass mesh.</div>
      <div class="rp-note rp-muted">Glass: {{ rp.windshieldText() }}</div>
      <BngButton @click="rp.rescanWindshield()">Re-scan windshield</BngButton>
      <BngButton @click="rp.sweep()">Single wiper sweep</BngButton>
    </RpSection>

    <RpSection title="Tyre spray & wakes" :open="state.open.spray" @toggle="rp.toggle('spray')">
      <RpSlider v-for="x in SLIDERS.spray" :key="x.k" v-bind="sliderProps(x)" @change="rp.set(x.k, $event)" />
      <BngSwitch :model-value="!!state.s.trafficSpray" @update:model-value="rp.set('trafficSpray', $event)">
        Other vehicles too (up to 8 tyres)
      </BngSwitch>
      <div class="rp-muted">Tyres: {{ state.diag.wheels || 0 }} tracked. Spray follows the tread speed, so wheelspin throws water too.</div>
    </RpSection>

    <RpSection title="Hydroplaning" :open="state.open.hydro" @toggle="rp.toggle('hydro')">
      <RpSelect label="Hydroplaning" :value="state.s.hydroplaning" :options="HYDRO_MODES"
        hint="Arcade: only deep puddles at speed, the water never carries more than 45 % of a tyre's load. Simcade: up to 65 %, a car still reacts to deep puddles at speed. Sim: up to 95 % (full aquaplaning at about 95 km/h in a deep puddle on a 2.2 bar road tyre)."
        @change="rp.set('hydroplaning', $event)" />
      <RpSlider v-for="x in SLIDERS.hydro" :key="x.k" v-bind="sliderProps(x)" @change="rp.set(x.k, $event)" />
      <BngSwitch :model-value="!!state.s.hydroTraffic" @update:model-value="rp.set('hydroTraffic', $event)">
        Other cars too (within 400 m)
      </BngSwitch>
      <BngSwitch :model-value="!!state.s.hydroDebug" @update:model-value="rp.set('hydroDebug', $event)">
        Show the contact patches (debug: blue = water, red = load on the water)
      </BngSwitch>
      <div class="rp-note rp-muted">{{ rp.hydroText() }}</div>
      <div class="rp-muted">Node by node: the tread nodes touching the road find the water under them (the road film and
        exactly the puddles you see, never under a roof), the tread drains what it can, and the water pressure in front of
        the tyre lifts each node off the road against the tyre's own pressure, so the game's tyre physics loses the grip
        there. The water the tyre pushes aside drags it back, so one wheel in a puddle pulls the car. Only on hard
        ground (asphalt, concrete, cobbles).</div>
    </RpSection>

    <RpSection title="Diagnostics" :open="state.open.debug" @toggle="rp.toggle('debug')">
      <RpSelect label="Debug view" :value="state.s.debugMode" :options="DEBUG_VIEWS" @change="rp.set('debugMode', $event)" />
      <BngSwitch :model-value="!!state.s.vehicleMask" @update:model-value="rp.set('vehicleMask', $event)">
        Vehicle mask (untick only to test)
      </BngSwitch>
      <BngSwitch :model-value="!!state.s.proceduralMasks" @update:model-value="rp.set('proceduralMasks', $event)">
        Procedural masks (no textures)
      </BngSwitch>
      <div v-for="(l, i) in rp.boxInfo()" :key="i" class="rp-muted rp-mono">{{ l }}</div>
      <div class="rp-muted">UI link: {{ state.transport || "none" }}{{ state.loaded ? ", connected" : "" }}</div>
      <BngButton @click="rp.selfTest()">Run self-test (prints to console)</BngButton>
    </RpSection>

    <div class="rp-actions">
      <BngButton @click="rp.save()">Save</BngButton>
      <BngButton @click="rp.reset()">Reset defaults</BngButton>
    </div>
  </div>
</template>

<script setup>
import { BngButton, BngSwitch } from "@/common/components/base"
import RpSection from "../components/RpSection.vue"
import RpSlider from "../components/RpSlider.vue"
import RpSelect from "../components/RpSelect.vue"
import { useRainPuddles } from "../shared/useRainPuddles.js"
import { TOGGLES, REFLECTION_MODES, HYDRO_MODES, SSR_QUALITIES, FALLBACK_MODES, DEBUG_VIEWS, SLIDERS, PRESETS } from "../shared/controls.js"
import { VERSION } from "../shared/constants.js"

const rp = useRainPuddles()
const state = rp.state

function sliderProps(x) {
  return { label: x.l, value: state.s[x.k], min: x.a, max: x.b, step: x.st, digits: x.d, hint: x.hint || "" }
}
</script>

<style scoped lang="scss">
.rp-panel {
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
  color: var(--bng-off-white);
  font-size: 0.9rem;
}
.rp-head {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
}
.rp-title {
  font-size: 1.15rem;
  font-weight: bold;
}
.rp-muted {
  color: var(--bng-cool-gray-300);
  font-size: 0.78rem;
  line-height: 1.4;
}
.rp-mono {
  font-family: monospace;
}
.rp-ok {
  color: #7fe08a;
}
.rp-bad {
  color: #ff8a80;
}
.rp-toggles {
  display: flex;
  flex-wrap: wrap;
  gap: 0.25rem 0.75rem;
}
.rp-note {
  margin: 0.35rem 0;
  padding: 0.3rem 0.45rem;
  border-left: 3px solid var(--bng-orange-500);
  background: rgba(var(--bng-cool-gray-800-rgb), 0.7);
}
.rp-warn {
  color: #ffb4a8;
}
.rp-sub {
  margin: 0.6rem 0 0.15rem;
  padding-bottom: 0.1rem;
  color: var(--bng-off-white);
  font-weight: bold;
  font-size: 0.85rem;
  letter-spacing: 0.03em;
  text-transform: uppercase;
  border-bottom: 1px dashed rgba(var(--bng-cool-gray-500-rgb), 0.5);
}
.rp-minor {
  margin: 0.4rem 0 0.1rem;
  color: var(--bng-orange-200);
  font-size: 0.8rem;
}
.rp-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  margin-top: 0.5rem;
}
</style>
