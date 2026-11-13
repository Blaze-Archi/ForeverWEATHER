<template>
  <div class="rp-select" :title="hint || ''">
    <div class="rp-select-label">{{ label }}</div>
    <!-- 1.0: the game's own dropdown. A native <select> never opens its list in the game's UI browser (it draws pop-ups
         of native controls nowhere), so the dropdowns of the panel did nothing. -->
    <BngDropdown class="rp-dropdown" :model-value="current" :items="items" @update:model-value="pick" />
  </div>
</template>

<script setup>
import { computed } from "vue"
import { BngDropdown } from "@/common/components/base"

const props = defineProps({
  label: { type: String, required: true },
  value: { type: [Number, String], default: 0 },
  options: { type: Array, required: true },
  hint: { type: String, default: "" },
})
const emit = defineEmits(["change"])

// options use { v, l }; the game's dropdown takes { value, label } and matches the value exactly (numbers here)
const items = computed(() => props.options.map(o => ({ value: Number(o.v), label: String(o.l) })))
const current = computed(() => Number(props.value))

function pick(v) {
  const n = Number(v)
  if (!Number.isNaN(n) && n !== current.value) emit("change", n)
}
</script>

<style scoped lang="scss">
.rp-select {
  margin: 0.35rem 0;
}
.rp-select-label {
  font-size: 0.85rem;
  margin-bottom: 0.15rem;
}
.rp-dropdown {
  width: 100%;
}
</style>
