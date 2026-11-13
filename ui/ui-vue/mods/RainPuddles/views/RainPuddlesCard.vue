<template>
  <div class="rp-card">
    <BngButton class="rp-open" @click="openSidePanel">Open side panel (scene stays visible)</BngButton>
    <div class="rp-scroll">
      <RainPuddlesPanel />
    </div>
  </div>
</template>

<script setup>
import { BngButton } from "@/common/components/base"
import RainPuddlesPanel from "./RainPuddlesPanel.vue"
import { ROUTE_NAME } from "../shared/constants.js"
import { openSidePanel as openRoute } from "../shared/useRainPuddles.js"

const openSidePanel = () => openRoute(ROUTE_NAME)
</script>

<style scoped lang="scss">
.rp-card {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding: 0.5rem;
}
.rp-scroll {
  max-height: 70vh;
  overflow-y: auto;
  padding-right: 0.4rem;
}
</style>
