<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  BaseTable,
  BaseTableRow,
  BaseTableCell,
} from 'dashboard/components-next/table';
import { PEOPLE_TABS } from './constants';

const props = defineProps({
  steps: {
    type: Array,
    default: () => [],
  },
  enrolledCount: {
    type: Number,
    default: 0,
  },
});

const emit = defineEmits(['filter']);

const { t } = useI18n();

const headers = computed(() => [
  t('SEQUENCE_REPORTS.FUNNEL.STEP'),
  t('SEQUENCE_REPORTS.FUNNEL.REACHED'),
  t('SEQUENCE_REPORTS.FUNNEL.SENT'),
  t('SEQUENCE_REPORTS.FUNNEL.FAILED'),
  t('SEQUENCE_REPORTS.FUNNEL.DEFERRED'),
  t('SEQUENCE_REPORTS.FUNNEL.WAITING'),
  t('SEQUENCE_REPORTS.FUNNEL.HELD'),
  t('SEQUENCE_REPORTS.FUNNEL.EXITED'),
]);

const percentOfEnrolled = count =>
  props.enrolledCount ? Math.round((count / props.enrolledCount) * 100) : 0;

// The columns that are a list of people on that step right now.
const drilldowns = [
  { key: 'waiting', status: 'active' },
  { key: 'held', status: 'held' },
  { key: 'exited', status: 'exited' },
];

const showPeople = (step, status) =>
  emit('filter', {
    tab: PEOPLE_TABS.ENROLLMENTS,
    status,
    current_step: step,
  });
</script>

<template>
  <section class="flex flex-col gap-2">
    <h3 class="text-heading-2 text-n-slate-12">
      {{ t('SEQUENCE_REPORTS.FUNNEL.TITLE') }}
    </h3>
    <p class="mb-0 text-body-main text-n-slate-11">
      {{ t('SEQUENCE_REPORTS.FUNNEL.DESCRIPTION') }}
    </p>
    <BaseTable
      :headers="headers"
      :items="steps"
      :no-data-message="t('SEQUENCE_REPORTS.FUNNEL.EMPTY')"
    >
      <template #row="{ items }">
        <BaseTableRow v-for="item in items" :key="item.step" :item="item">
          <BaseTableCell>
            <span class="text-n-slate-12">{{ item.step }}</span>
          </BaseTableCell>
          <BaseTableCell>
            <span class="text-n-slate-12 tabular-nums">{{ item.reached }}</span>
            <span class="text-n-slate-10 tabular-nums ms-1">
              {{
                t('SEQUENCE_REPORTS.FUNNEL.PERCENT', {
                  percent: percentOfEnrolled(item.reached),
                })
              }}
            </span>
          </BaseTableCell>
          <BaseTableCell>
            <span class="tabular-nums">{{ item.sent }}</span>
          </BaseTableCell>
          <BaseTableCell>
            <span
              class="tabular-nums"
              :class="{ 'text-n-ruby-11': item.failed }"
            >
              {{ item.failed }}
            </span>
          </BaseTableCell>
          <BaseTableCell>
            <span class="tabular-nums">{{ item.deferred }}</span>
          </BaseTableCell>
          <BaseTableCell v-for="column in drilldowns" :key="column.key">
            <button
              v-if="item[column.key]"
              type="button"
              class="tabular-nums text-n-blue-11 hover:underline"
              @click="showPeople(item.step, column.status)"
            >
              {{ item[column.key] }}
            </button>
            <span v-else class="tabular-nums">{{ item[column.key] }}</span>
          </BaseTableCell>
        </BaseTableRow>
      </template>
    </BaseTable>
  </section>
</template>
