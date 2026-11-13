<template>
  <section class="rp-section">
    <button class="rp-section-title" type="button" @click="$emit('toggle')">
      <span>{{ title }}</span>
      <span class="rp-sign">{{ open ? "−" : "+" }}</span>
    </button>
    <div v-if="open" class="rp-section-body">
      <slot />
    </div>
  </section>
</template>

<script setup>
defineProps({
  title: { type: String, required: true },
  open: { type: Boolean, default: false },
})
defineEmits(["toggle"])
</script>

<style scoped lang="scss">
.rp-section {
  margin: 0.4rem 0;
}
.rp-section-title {
  display: flex;
  justify-content: space-between;
  width: 100%;
  padding: 0.35rem 0.25rem;
  border: 0;
  border-bottom: 1px solid rgba(var(--bng-cool-gray-500-rgb), 0.6);
  background: transparent;
  color: var(--bng-orange-300);
  font-weight: bold;
  font-size: 0.95rem;
  text-align: left;
  cursor: pointer;
  &:hover {
    color: var(--bng-orange-200);
  }
}
.rp-section-body {
  padding: 0.25rem 0.25rem 0.5rem;
}
</style>
