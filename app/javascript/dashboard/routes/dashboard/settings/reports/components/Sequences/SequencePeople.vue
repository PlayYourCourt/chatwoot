<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import SequenceReportsAPI from 'dashboard/api/sequenceReports';
import Button from 'dashboard/components-next/button/Button.vue';
import PaginationFooter from 'dashboard/components-next/pagination/PaginationFooter.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import {
  BaseTable,
  BaseTableRow,
  BaseTableCell,
} from 'dashboard/components-next/table';
import SequenceStatusBadge from './SequenceStatusBadge.vue';
import { PEOPLE_TABS } from './constants';
import { formatTimestamp, humanize, n8nExecutionUrl } from './helpers';

const props = defineProps({
  // { flow, since, until } for a report, or { q } for a search across every flow and date
  scope: {
    type: Object,
    required: true,
  },
  // { tab, status, exit_reason, current_step, outcome }: what a click on a count narrowed the list to
  filter: {
    type: Object,
    required: true,
  },
  n8nUrl: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['update:filter', 'select']);

const { t } = useI18n();

const records = ref([]);
const totalCount = ref(0);
const perPage = ref(25);
const currentPage = ref(1);
const isFetching = ref(false);

const tabs = computed(() => [
  {
    key: PEOPLE_TABS.ENROLLMENTS,
    label: t('SEQUENCE_REPORTS.PEOPLE.ENROLLMENTS'),
  },
  { key: PEOPLE_TABS.ATTEMPTS, label: t('SEQUENCE_REPORTS.PEOPLE.ATTEMPTS') },
]);

const activeTab = computed(() => props.filter.tab || PEOPLE_TABS.ENROLLMENTS);
const activeTabIndex = computed(() =>
  tabs.value.findIndex(tab => tab.key === activeTab.value)
);
const isAttempts = computed(() => activeTab.value === PEOPLE_TABS.ATTEMPTS);

const filterLabels = computed(() => ({
  status: value => t('SEQUENCE_REPORTS.PEOPLE.FILTERS.STATUS', { value }),
  exit_reason: value =>
    t('SEQUENCE_REPORTS.PEOPLE.FILTERS.EXIT_REASON', { value }),
  current_step: value =>
    t('SEQUENCE_REPORTS.PEOPLE.FILTERS.CURRENT_STEP', { value }),
  outcome: value => t('SEQUENCE_REPORTS.PEOPLE.FILTERS.OUTCOME', { value }),
}));

const activeFilters = computed(() =>
  Object.entries(props.filter)
    .filter(([key, value]) => filterLabels.value[key] && value)
    .map(([key, value]) => ({
      key,
      label: filterLabels.value[key](humanize(value)),
    }))
);

const enrollmentHeaders = computed(() => [
  t('SEQUENCE_REPORTS.PEOPLE.CONTACT'),
  t('SEQUENCE_REPORTS.PEOPLE.FLOW'),
  t('SEQUENCE_REPORTS.PEOPLE.STATUS'),
  t('SEQUENCE_REPORTS.PEOPLE.STEP'),
  t('SEQUENCE_REPORTS.PEOPLE.ENROLLED_AT'),
  t('SEQUENCE_REPORTS.PEOPLE.NEXT_RUN_AT'),
  t('SEQUENCE_REPORTS.PEOPLE.REASON'),
]);

const attemptHeaders = computed(() => [
  t('SEQUENCE_REPORTS.PEOPLE.CONTACT'),
  t('SEQUENCE_REPORTS.PEOPLE.FLOW'),
  t('SEQUENCE_REPORTS.PEOPLE.OUTCOME'),
  t('SEQUENCE_REPORTS.PEOPLE.SOURCE'),
  t('SEQUENCE_REPORTS.PEOPLE.ATTEMPTED_AT'),
  '',
]);

// Only an active enrollment has a step ahead of it.
const nextRunAt = record =>
  record.status === 'active' ? formatTimestamp(record.next_run_at) : '';

const contactName = record =>
  record.contact?.name || record.email || record.phone || '';
const contactDetail = record =>
  [record.contact?.email || record.email, record.phone]
    .filter(Boolean)
    .join(' · ');

const fetchRecords = async () => {
  const { tab, ...filters } = props.filter;
  const params = { ...props.scope, ...filters, page: currentPage.value };
  isFetching.value = true;
  try {
    const { data } = isAttempts.value
      ? await SequenceReportsAPI.getAttempts(params)
      : await SequenceReportsAPI.getEnrollments(params);
    records.value = data.payload;
    totalCount.value = data.meta.count;
    perPage.value = data.meta.per_page;
  } catch {
    useAlert(t('SEQUENCE_REPORTS.FETCH_FAILED'));
  } finally {
    isFetching.value = false;
  }
};

watch(
  [() => props.scope, () => props.filter],
  () => {
    currentPage.value = 1;
    fetchRecords();
  },
  { deep: true, immediate: true }
);

const onPageChange = page => {
  currentPage.value = page;
  fetchRecords();
};

// A filter belongs to one list (a status to enrollments, an outcome to attempts), so switching lists drops them.
const onTabChange = tab => emit('update:filter', { tab: tab.key });

const clearFilter = key => {
  const { [key]: removed, ...rest } = props.filter;
  emit('update:filter', rest);
};
</script>

<template>
  <section class="flex flex-col gap-3">
    <div class="flex flex-wrap items-center gap-3">
      <TabBar
        :tabs="tabs"
        :initial-active-tab="activeTabIndex"
        @tab-changed="onTabChange"
      />
      <Button
        v-for="item in activeFilters"
        :key="item.key"
        :label="item.label"
        icon="i-lucide-x"
        trailing-icon
        outline
        slate
        xs
        @click="clearFilter(item.key)"
      />
      <Spinner v-if="isFetching" />
    </div>
    <BaseTable
      v-if="isAttempts"
      :headers="attemptHeaders"
      :items="records"
      :loading="isFetching"
      :no-data-message="t('SEQUENCE_REPORTS.PEOPLE.EMPTY_ATTEMPTS')"
    >
      <template #row="{ items }">
        <BaseTableRow v-for="item in items" :key="item.id" :item="item">
          <BaseTableCell>
            <div class="flex flex-col">
              <span class="text-n-slate-12">{{ contactName(item) }}</span>
              <span class="text-label-small text-n-slate-10">
                {{ contactDetail(item) }}
              </span>
            </div>
          </BaseTableCell>
          <BaseTableCell>{{ item.flow_key }}</BaseTableCell>
          <BaseTableCell>
            <SequenceStatusBadge :status="item.outcome" />
          </BaseTableCell>
          <BaseTableCell>{{ item.source }}</BaseTableCell>
          <BaseTableCell>
            <span class="whitespace-nowrap">
              {{ formatTimestamp(item.attempted_at) }}
            </span>
          </BaseTableCell>
          <BaseTableCell align="end">
            <div class="flex items-center justify-end gap-3">
              <button
                v-if="item.enrollment_id"
                type="button"
                class="whitespace-nowrap text-n-blue-11 hover:underline"
                @click="emit('select', item.enrollment_id)"
              >
                {{ t('SEQUENCE_REPORTS.PEOPLE.VIEW_TIMELINE') }}
              </button>
              <a
                v-if="n8nExecutionUrl(n8nUrl, item, item.attempted_at)"
                :href="n8nExecutionUrl(n8nUrl, item, item.attempted_at)"
                target="_blank"
                rel="noopener noreferrer"
                class="whitespace-nowrap text-n-blue-11 hover:underline"
              >
                {{ t('SEQUENCE_REPORTS.OPEN_IN_N8N') }}
              </a>
            </div>
          </BaseTableCell>
        </BaseTableRow>
      </template>
    </BaseTable>
    <BaseTable
      v-else
      :headers="enrollmentHeaders"
      :items="records"
      :loading="isFetching"
      :no-data-message="t('SEQUENCE_REPORTS.PEOPLE.EMPTY_ENROLLMENTS')"
    >
      <template #row="{ items }">
        <BaseTableRow
          v-for="item in items"
          :key="item.id"
          :item="item"
          class="cursor-pointer hover:bg-n-alpha-1"
          @click="emit('select', item.id)"
        >
          <BaseTableCell>
            <div class="flex flex-col">
              <span class="text-n-slate-12">{{ contactName(item) }}</span>
              <span class="text-label-small text-n-slate-10">
                {{ contactDetail(item) }}
              </span>
            </div>
          </BaseTableCell>
          <BaseTableCell>{{ item.flow_key }}</BaseTableCell>
          <BaseTableCell>
            <SequenceStatusBadge :status="item.status" />
          </BaseTableCell>
          <BaseTableCell>{{ item.current_step }}</BaseTableCell>
          <BaseTableCell>
            <span class="whitespace-nowrap">
              {{ formatTimestamp(item.enrolled_at) }}
            </span>
          </BaseTableCell>
          <BaseTableCell>
            <span class="whitespace-nowrap">{{ nextRunAt(item) }}</span>
          </BaseTableCell>
          <BaseTableCell>{{ humanize(item.exit_reason) }}</BaseTableCell>
        </BaseTableRow>
      </template>
    </BaseTable>
    <PaginationFooter
      v-if="totalCount > perPage"
      :current-page="currentPage"
      :total-items="totalCount"
      :items-per-page="perPage"
      @update:current-page="onPageChange"
    />
  </section>
</template>
