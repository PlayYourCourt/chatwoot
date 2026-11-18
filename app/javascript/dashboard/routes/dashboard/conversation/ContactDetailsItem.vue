<script>
export default {
  props: {
    title: { type: String, required: true },
    value: { type: [String, Number], default: '' },
    compact: { type: Boolean, default: false },
  },
};
</script>

<template>
  <div
    class="overflow-auto"
    :class="compact ? 'py-0 px-0' : 'flex items-start gap-2 py-1.5 px-3'"
  >
    <div
      class="items-center flex justify-between"
      :class="compact ? 'mb-1.5' : 'w-[7.5rem] shrink-0 min-h-6'"
    >
      <span class="text-sm font-medium text-n-slate-12">
        {{ title }}
      </span>
      <slot name="button" />
    </div>
    <div
      v-if="value"
      class="break-words"
      :class="{ 'flex-1 min-w-0 text-sm leading-6': !compact }"
    >
      <slot>
        {{ value }}
      </slot>
    </div>
  </div>
</template>
