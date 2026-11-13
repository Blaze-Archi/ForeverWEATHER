<template>
  <div
    v-bng-scoped-nav="{
      scopeId: 'rain-puddles-route',
      canDeactivate: () => false,
      preferAutoFocus: true,
      trapPolicy: SCOPE_TRAP_POLICIES.ALWAYS,
    }"
    class="rp-route"
    tabindex="-1"
  >
    <aside class="rp-side" v-bng-blur>
      <BngButton
        class="rp-back"
        bng-scoped-nav-autofocus
        :accent="ACCENTS.custom_old"
        :icon-left="icons.arrowSmallLeft"
        sound-class="bng_back_hover_generic"
        v-bng-on-ui-nav:back,menu.asMouse
        @click="goBack"
      >
        <BngBinding ui-event="back" controller track-ignore />
        {{ $tt("ui.common.back") }}
      </BngButton>
      <div class="rp-scroll">
        <RainPuddlesPanel />
      </div>
    </aside>
  </div>
</template>

<script setup>
import { BngButton, BngBinding, ACCENTS, icons } from "@/common/components/base"
import { vBngOnUiNav, vBngBlur, vBngScopedNav } from "@/common/directives"
import { SCOPE_TRAP_POLICIES } from "@/services/scopedNav/types"
import SysInfo from "@/services/sysInfo"
import RainPuddlesPanel from "./RainPuddlesPanel.vue"

const bngVue = window.bngVue || { gotoGameState() {}, goBack() {} }

async function goBack() {
  if (await SysInfo.isInGame()) {
    return bngVue.gotoGameState("pause")
  }
  return bngVue.goBack()
}
</script>

<style lang="scss" scoped>
.rp-route {
  position: absolute;
  inset: 0;
  pointer-events: all;
  background: transparent;   // the scene stays visible for live tuning
}
.rp-side {
  position: absolute;
  top: 1.5rem;
  bottom: 1.5rem;
  left: 1.5rem;
  width: 25rem;
  max-width: 45vw;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  padding: 0.9rem;
  background-color: rgba(var(--bng-cool-gray-900-rgb), 0.82);
  border: 1px solid rgba(var(--bng-orange-400-rgb), 0.45);
  border-radius: var(--bng-corners-2);
  box-shadow: 0 1rem 2.5rem rgba(0, 0, 0, 0.3);
}
.rp-scroll {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  padding-right: 0.4rem;
}
.rp-back {
  --bng-button-custom-margin: 0;
  --bng-button-margin: 0;
  --bng-button-custom-enabled: var(--bng-off-black);
  --bng-button-custom-hover: var(--bng-orange-600);
  --bng-button-custom-active: var(--bng-orange-800);
  --bng-button-custom-border-enabled: var(--bng-cool-gray-600);
  --bng-button-custom-border-hover: var(--bng-orange-400);
  --bng-button-custom-border-active: var(--bng-orange-600);
  --bng-button-custom-border-radius: var(--bng-corners-2);
  --bng-button-padding: 0.25em 0.75em;
  align-self: flex-start;
  margin: 0 !important;
}
</style>
