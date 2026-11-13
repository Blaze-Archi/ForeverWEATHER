<template>
  <div class="rp-slider" :title="hint || ''">
    <div class="rp-slider-label">
      <span>{{ label }}</span>
      <b>{{ shown }}</b>
    </div>
    <input
      type="range"
      :min="min"
      :max="max"
      :step="step"
      :value="current"
      @input="$emit('change', Number($event.target.value))"
    />
  </div>
</template>

<script setup>
import { computed } from "vue"

const props = defineProps({
  label: { type: String, required: true },
  value: { type: [Number, String], default: 0 },
  min: { type: Number, default: 0 },
  max: { type: Number, default: 1 },
  step: { type: Number, default: 0.01 },
  digits: { type: Number, default: 2 },
  hint: { type: String, default: "" },
})
defineEmits(["change"])

const current = computed(() => {
  const v = Number(props.value)
  return isFinite(v) ? v : props.min
})
const shown = computed(() => current.value.toFixed(props.digits))
</script>

<style scoped lang="scss">
.rp-slider {
  margin: 0.3rem 0;
}
.rp-slider-label {
  display: flex;
  justify-content: space-between;
  gap: 0.5rem;
  font-size: 0.85rem;
  b {
    color: var(--bng-orange-200);
    font-variant-numeric: tabular-nums;
  }
}
input[type="range"] {
  width: 100%;
  accent-color: var(--bng-orange-500);
  cursor: pointer;
}
</style>
