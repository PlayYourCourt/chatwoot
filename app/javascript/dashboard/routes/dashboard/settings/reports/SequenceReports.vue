<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import subDays from 'date-fns/subDays';
import { getUnixStartOfDay, getUnixEndOfDay } from 'helpers/DateHelper';
import { useAlert } from 'dashboard/composables';
import SequenceReportsAPI from 'dashboard/api/sequenceReports';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import WootDatePicker from 'dashboard/components/ui/DatePicker/DatePicker.vue';
import ReportHeader from './components/ReportHeader.vue';
import SequenceErrors from './components/Sequences/SequenceErrors.vue';
import SequenceExits from './components/Sequences/SequenceExits.vue';
import SequenceFunnel from './components/Sequences/SequenceFunnel.vue';
import SequencePeople from './components/Sequences/SequencePeople.vue';
import SequenceSummaryCards from './components/Sequences/SequenceSummaryCards.vue';
import SequenceTimeline from './components/Sequences/SequenceTimeline.vue';
import { PEOPLE_TABS } from './components/Sequences/constants';

const DEFAULT_RANGE_DAYS = 29;

const { t } = useI18n();

const flows = ref([]);
const n8nUrl = ref('');
const selectedFlow = ref('');
const dateRange = ref([subDays(new Date(), DEFAULT_RANGE_DAYS), new Date()]);
const rangeType = ref('last30days');
const summary = ref(null);
const isFetchingSummary = ref(false);
const searchInput = ref('');
const searchQuery = ref('');
const peopleFilter = ref({ tab: PEOPLE_TABS.ENROLLMENTS });
const selectedEnrollmentId = ref(null);
const peopleSection = ref(null);

const flowOptions = computed(() =>
  flows.value.map(flow => ({
    value: flow.key,
    label:
      flow.status === 'active'
        ? flow.name
        : t('SEQUENCE_REPORTS.FLOW_PAUSED', { name: flow.name }),
  }))
);

const since = computed(() => getUnixStartOfDay(dateRange.value[0]));
const until = computed(() => getUnixEndOfDay(dateRange.value[1]));

const isSearching = computed(() => !!searchQuery.value);

// A search looks across every flow and date; otherwise the list follows the flow and range of the report.
const peopleScope = computed(() =>
  isSearching.value
    ? { q: searchQuery.value }
    : { flow: selectedFlow.value, since: since.value, until: until.value }
);

const enrolledCount = computed(() =>
  Object.values(summary.value?.enrollments || {}).reduce((a, b) => a + b, 0)
);

const fetchSummary = async () => {
  if (!selectedFlow.value) return;
  isFetchingSummary.value = true;
  try {
    const { data } = await SequenceReportsAPI.getSummary({
      flow: selectedFlow.value,
      since: since.value,
      until: until.value,
    });
    summary.value = data;
  } catch {
    useAlert(t('SEQUENCE_REPORTS.FETCH_FAILED'));
  } finally {
    isFetchingSummary.value = false;
  }
};

const fetchFlows = async () => {
  try {
    const { data } = await SequenceReportsAPI.get();
    flows.value = data.flows;
    n8nUrl.value = data.n8n_url || '';
    selectedFlow.value = data.flows[0]?.key || '';
  } catch {
    useAlert(t('SEQUENCE_REPORTS.FETCH_FAILED'));
  }
};

const onDateRangeChange = ([startDate, endDate, type]) => {
  dateRange.value = [startDate, endDate];
  rangeType.value = type;
};

const resetPeopleFilter = () => {
  peopleFilter.value = { tab: PEOPLE_TABS.ENROLLMENTS };
};

// A count in the cards or tables narrows the list of people below and brings it into view.
const showPeople = filter => {
  peopleFilter.value = filter;
  peopleSection.value?.scrollIntoView({ behavior: 'smooth' });
};

const applySearch = () => {
  searchQuery.value = searchInput.value.trim();
  resetPeopleFilter();
};

const clearSearch = () => {
  searchInput.value = '';
  searchQuery.value = '';
  resetPeopleFilter();
};

watch([selectedFlow, since, until], () => {
  resetPeopleFilter();
  fetchSummary();
});

onMounted(fetchFlows);
</script>

<template>
  <ReportHeader
    :header-title="t('SEQUENCE_REPORTS.HEADER')"
    :header-description="t('SEQUENCE_REPORTS.DESCRIPTION')"
  />
  <div class="flex flex-col gap-8 pb-8">
    <div
      class="flex flex-col flex-wrap w-full gap-3 md:flex-row md:items-center"
    >
      <Select
        v-model="selectedFlow"
        :options="flowOptions"
        :aria-label="t('SEQUENCE_REPORTS.FLOW')"
        :disabled="isSearching"
      />
      <WootDatePicker
        v-model:date-range="dateRange"
        v-model:range-type="rangeType"
        @date-range-changed="onDateRangeChange"
      />
      <div class="flex items-center gap-2 md:ms-auto">
        <Input
          v-model="searchInput"
          size="sm"
          class="w-72"
          :placeholder="t('SEQUENCE_REPORTS.SEARCH_PLACEHOLDER')"
          @enter="applySearch"
        />
        <Button
          v-if="isSearching"
          :label="t('SEQUENCE_REPORTS.CLEAR_SEARCH')"
          ghost
          slate
          sm
          @click="clearSearch"
        />
        <Button
          v-else
          :label="t('SEQUENCE_REPORTS.SEARCH')"
          faded
          slate
          sm
          @click="applySearch"
        />
      </div>
    </div>

    <template v-if="!isSearching">
      <div
        v-if="isFetchingSummary && !summary"
        class="flex justify-center py-10"
      >
        <Spinner />
      </div>
      <template v-else-if="summary">
        <SequenceSummaryCards
          :attempts="summary.attempts"
          :enrollments="summary.enrollments"
          @filter="showPeople"
        />
        <SequenceFunnel
          :steps="summary.steps"
          :enrolled-count="enrolledCount"
          @filter="showPeople"
        />
        <SequenceExits :exits="summary.exits" @filter="showPeople" />
        <SequenceErrors
          v-if="summary.errors.length"
          :errors="summary.errors"
          :n8n-url="n8nUrl"
        />
      </template>
    </template>

    <div
      v-if="isSearching || selectedFlow"
      ref="peopleSection"
      class="flex flex-col gap-2"
    >
      <h3 class="text-heading-2 text-n-slate-12">
        {{
          isSearching
            ? t('SEQUENCE_REPORTS.PEOPLE.SEARCH_TITLE', { query: searchQuery })
            : t('SEQUENCE_REPORTS.PEOPLE.TITLE')
        }}
      </h3>
      <SequencePeople
        v-model:filter="peopleFilter"
        :scope="peopleScope"
        :n8n-url="n8nUrl"
        @select="selectedEnrollmentId = $event"
      />
    </div>
  </div>
  <SequenceTimeline
    :enrollment-id="selectedEnrollmentId"
    :n8n-url="n8nUrl"
    @close="selectedEnrollmentId = null"
  />
</template>
