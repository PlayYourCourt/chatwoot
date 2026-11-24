<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  ENROLLED_OUTCOME,
  ENROLLMENT_STATUSES,
  PEOPLE_TABS,
} from './constants';
import { humanize } from './helpers';

const props = defineProps({
  attempts: {
    type: Object,
    default: () => ({}),
  },
  enrollments: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['filter']);

const { t } = useI18n();

const sum = counts => Object.values(counts).reduce((a, b) => a + b, 0);

const enrolledCount = computed(() => sum(props.enrollments));

const statusLabels = computed(() => ({
  active: t('SEQUENCE_REPORTS.STATUS.ACTIVE'),
  completed: t('SEQUENCE_REPORTS.STATUS.COMPLETED'),
  exited: t('SEQUENCE_REPORTS.STATUS.EXITED'),
  held: t('SEQUENCE_REPORTS.STATUS.HELD'),
}));

const cards = computed(() => [
  {
    key: 'attempts',
    label: t('SEQUENCE_REPORTS.CARDS.ATTEMPTS'),
    count: sum(props.attempts),
    filter: { tab: PEOPLE_TABS.ATTEMPTS },
  },
  {
    key: 'enrolled',
    label: t('SEQUENCE_REPORTS.CARDS.ENROLLED'),
    count: enrolledCount.value,
    filter: { tab: PEOPLE_TABS.ENROLLMENTS },
  },
  ...ENROLLMENT_STATUSES.map(status => ({
    key: status,
    label: statusLabels.value[status],
    count: props.enrollments[status] || 0,
    filter: { tab: PEOPLE_TABS.ENROLLMENTS, status },
  })),
]);

const refusals = computed(() =>
  Object.entries(props.attempts)
    .filter(([outcome]) => outcome !== ENROLLED_OUTCOME)
    .sort(([, a], [, b]) => b - a)
    .map(([outcome, count]) => ({ outcome, count }))
);
</script>

<template>
  <div class="flex flex-col gap-3">
    <div class="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
      <button
        v-for="card in cards"
        :key="card.key"
        type="button"
        class="flex flex-col items-start gap-1 px-5 py-4 text-start rounded-xl outline outline-1 outline-n-container bg-n-solid-2 hover:bg-n-alpha-1"
        @click="emit('filter', card.filter)"
      >
        <span class="text-body-main text-n-slate-11">{{ card.label }}</span>
        <span class="text-heading-1 text-n-slate-12 tabular-nums">
          {{ card.count }}
        </span>
      </button>
    </div>
    <div v-if="refusals.length" class="flex flex-wrap items-center gap-2">
      <span class="text-body-main text-n-slate-11">
        {{ t('SEQUENCE_REPORTS.CARDS.NOT_ENROLLED') }}
      </span>
      <button
        v-for="refusal in refusals"
        :key="refusal.outcome"
        type="button"
        class="inline-flex items-center gap-1.5 px-2 py-1 rounded-md text-label-small bg-n-amber-3 text-n-amber-11 hover:bg-n-amber-4"
        @click="
          emit('filter', {
            tab: PEOPLE_TABS.ATTEMPTS,
            outcome: refusal.outcome,
          })
        "
      >
        {{ humanize(refusal.outcome) }}
        <span class="tabular-nums">{{ refusal.count }}</span>
      </button>
    </div>
  </div>
</template>
