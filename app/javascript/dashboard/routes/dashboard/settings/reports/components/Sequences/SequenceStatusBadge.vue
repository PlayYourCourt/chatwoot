<script setup>
import { computed } from 'vue';
import { STATUS_COLOR_CLASSES, DEFAULT_STATUS_COLOR_CLASS } from './constants';
import { humanize } from './helpers';

const props = defineProps({
  status: {
    type: String,
    default: '',
  },
});

const colorClass = computed(
  () => STATUS_COLOR_CLASSES[props.status] || DEFAULT_STATUS_COLOR_CLASS
);
</script>

<template>
  <span
    class="inline-flex items-center px-2 py-0.5 rounded-md text-label-small whitespace-nowrap"
    :class="colorClass"
  >
    {{ humanize(status) }}
  </span>
</template>
