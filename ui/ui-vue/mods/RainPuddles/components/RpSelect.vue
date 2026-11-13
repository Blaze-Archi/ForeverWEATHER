<template>
  <div class="rp-select" :title="hint || ''">
    <div class="rp-select-label">{{ label }}</div>
    <select :value="value" @change="$emit('change', Number($event.target.value))">
      <option v-for="o in options" :key="o.v" :value="o.v">{{ o.l }}</option>
    </select>
  </div>
</template>

<script setup>
defineProps({
  label: { type: String, required: true },
  value: { type: [Number, String], default: 0 },
  options: { type: Array, required: true },
  hint: { type: String, default: "" },
})
defineEmits(["change"])
</script>

<style scoped lang="scss">
.rp-select {
  margin: 0.35rem 0;
}
.rp-select-label {
  font-size: 0.85rem;
  margin-bottom: 0.15rem;
}
select {
  width: 100%;
  padding: 0.2rem 0.3rem;
  color: var(--bng-off-white);
  background: rgba(var(--bng-cool-gray-800-rgb), 0.95);
  border: 1px solid rgba(var(--bng-cool-gray-500-rgb), 0.8);
  border-radius: var(--bng-corners-1);
}
</style>
