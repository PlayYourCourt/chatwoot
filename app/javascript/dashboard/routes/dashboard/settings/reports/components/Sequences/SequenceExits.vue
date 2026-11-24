<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  BaseTable,
  BaseTableRow,
  BaseTableCell,
} from 'dashboard/components-next/table';
import { PEOPLE_TABS } from './constants';
import { humanize } from './helpers';

const props = defineProps({
  exits: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['filter']);

const { t } = useI18n();

const headers = computed(() => [
  t('SEQUENCE_REPORTS.EXITS.REASON'),
  t('SEQUENCE_REPORTS.EXITS.STEP'),
  t('SEQUENCE_REPORTS.EXITS.PEOPLE'),
]);

const sortedExits = computed(() =>
  [...props.exits].sort((a, b) => b.count - a.count)
);

const showPeople = exit =>
  emit('filter', {
    tab: PEOPLE_TABS.ENROLLMENTS,
    status: 'exited',
    exit_reason: exit.reason,
    current_step: exit.step,
  });
</script>

<template>
  <section class="flex flex-col gap-2">
    <h3 class="text-heading-2 text-n-slate-12">
      {{ t('SEQUENCE_REPORTS.EXITS.TITLE') }}
    </h3>
    <BaseTable
      :headers="headers"
      :items="sortedExits"
      :no-data-message="t('SEQUENCE_REPORTS.EXITS.EMPTY')"
    >
      <template #row="{ items }">
        <BaseTableRow
          v-for="item in items"
          :key="`${item.step}:${item.reason}`"
          :item="item"
        >
          <BaseTableCell>
            <span class="text-n-slate-12">{{ humanize(item.reason) }}</span>
          </BaseTableCell>
          <BaseTableCell>{{ item.step }}</BaseTableCell>
          <BaseTableCell>
            <button
              type="button"
              class="tabular-nums text-n-blue-11 hover:underline"
              @click="showPeople(item)"
            >
              {{ item.count }}
            </button>
          </BaseTableCell>
        </BaseTableRow>
      </template>
    </BaseTable>
  </section>
</template>
