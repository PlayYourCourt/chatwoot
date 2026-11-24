<script setup>
import { computed, nextTick, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import SequenceReportsAPI from 'dashboard/api/sequenceReports';
import { frontendURL } from 'dashboard/helper/URLHelper';
import SidePanel from 'dashboard/components-next/side-panel/SidePanel.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import SequenceStatusBadge from './SequenceStatusBadge.vue';
import {
  formatTimestamp,
  humanize,
  n8nExecutionUrl,
  readableReason,
} from './helpers';

const props = defineProps({
  enrollmentId: {
    type: Number,
    default: null,
  },
  n8nUrl: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['close']);

const { t } = useI18n();
const accountId = useMapGetter('getCurrentAccountId');

const panelRef = ref(null);
const details = ref(null);
const isFetching = ref(false);

const enrollment = computed(() => details.value?.enrollment);
const contact = computed(() => enrollment.value?.contact);

const title = computed(
  () =>
    contact.value?.name ||
    enrollment.value?.phone ||
    t('SEQUENCE_REPORTS.TIMELINE.TITLE')
);

const facts = computed(() => {
  if (!enrollment.value) return [];
  const row = enrollment.value;
  return [
    [t('SEQUENCE_REPORTS.PEOPLE.FLOW'), row.flow_key],
    [t('SEQUENCE_REPORTS.PEOPLE.STEP'), row.current_step],
    [t('SEQUENCE_REPORTS.TIMELINE.PHONE'), row.phone],
    [t('SEQUENCE_REPORTS.PEOPLE.SOURCE'), row.source],
    [
      t('SEQUENCE_REPORTS.PEOPLE.ENROLLED_AT'),
      formatTimestamp(row.enrolled_at),
    ],
    [t('SEQUENCE_REPORTS.TIMELINE.ENDED_AT'), formatTimestamp(row.ended_at)],
    [
      t('SEQUENCE_REPORTS.TIMELINE.NEXT_RUN_AT'),
      row.status === 'active' ? formatTimestamp(row.next_run_at) : '',
    ],
    [t('SEQUENCE_REPORTS.PEOPLE.REASON'), humanize(row.exit_reason)],
  ].filter(([, value]) => value);
});

// Decisions (step logs) and texts (message logs) in the order they happened.
const events = computed(() => {
  if (!details.value) return [];
  const decisions = details.value.step_logs.map(log => ({
    key: `step-${log.id}`,
    at: log.ran_at,
    step: log.step,
    status: log.outcome,
    text: log.reason,
    record: log,
  }));
  const texts = details.value.message_logs.map(log => ({
    key: `message-${log.id}`,
    at: log.sent_at,
    step: log.step,
    status: log.status,
    text: log.error,
    body: log.body,
    conversationId: log.conversation_id,
    record: log,
  }));
  return [...decisions, ...texts].sort(
    (a, b) => new Date(a.at) - new Date(b.at)
  );
});

const contactUrl = computed(() =>
  contact.value
    ? frontendURL(`accounts/${accountId.value}/contacts/${contact.value.id}`)
    : ''
);
const conversationUrl = conversationId =>
  frontendURL(`accounts/${accountId.value}/conversations/${conversationId}`);

const fetchDetails = async id => {
  details.value = null;
  isFetching.value = true;
  try {
    const { data } = await SequenceReportsAPI.getEnrollment(id);
    details.value = data;
  } catch {
    useAlert(t('SEQUENCE_REPORTS.FETCH_FAILED'));
  } finally {
    isFetching.value = false;
  }
};

watch(
  () => props.enrollmentId,
  async id => {
    if (!id) return;
    await nextTick();
    panelRef.value?.open();
    fetchDetails(id);
  }
);
</script>

<template>
  <SidePanel ref="panelRef" width="2xl" :title="title" @close="emit('close')">
    <div v-if="isFetching" class="flex justify-center py-10">
      <Spinner />
    </div>
    <div v-else-if="enrollment" class="flex flex-col gap-6">
      <div class="flex flex-wrap items-center gap-3">
        <SequenceStatusBadge :status="enrollment.status" />
        <span v-if="contact?.email" class="text-body-main text-n-slate-11">
          {{ contact.email }}
        </span>
        <a
          v-if="contactUrl"
          :href="contactUrl"
          target="_blank"
          rel="noopener noreferrer"
          class="text-body-main text-n-blue-11 hover:underline"
        >
          {{ t('SEQUENCE_REPORTS.TIMELINE.OPEN_CONTACT') }}
        </a>
      </div>
      <dl class="grid grid-cols-2 gap-x-6 gap-y-3 m-0">
        <div v-for="[label, value] in facts" :key="label" class="flex flex-col">
          <dt class="text-label-small text-n-slate-10">{{ label }}</dt>
          <dd class="m-0 text-body-main text-n-slate-12">{{ value }}</dd>
        </div>
      </dl>
      <ol class="flex flex-col gap-3 p-0 m-0 list-none">
        <li
          v-for="event in events"
          :key="event.key"
          class="flex flex-col gap-2 px-4 py-3 rounded-xl outline outline-1 outline-n-container bg-n-solid-2"
        >
          <div class="flex flex-wrap items-center gap-2">
            <span class="text-heading-3 text-n-slate-12">
              {{ t('SEQUENCE_REPORTS.TIMELINE.STEP', { step: event.step }) }}
            </span>
            <SequenceStatusBadge :status="event.status" />
            <span class="text-label-small text-n-slate-10">
              {{ formatTimestamp(event.at) }}
            </span>
            <span class="flex-1" />
            <a
              v-if="event.conversationId"
              :href="conversationUrl(event.conversationId)"
              target="_blank"
              rel="noopener noreferrer"
              class="text-label-small text-n-blue-11 hover:underline"
            >
              {{ t('SEQUENCE_REPORTS.TIMELINE.OPEN_CONVERSATION') }}
            </a>
            <a
              v-if="n8nExecutionUrl(n8nUrl, event.record, event.at)"
              :href="n8nExecutionUrl(n8nUrl, event.record, event.at)"
              target="_blank"
              rel="noopener noreferrer"
              class="text-label-small text-n-blue-11 hover:underline"
            >
              {{ t('SEQUENCE_REPORTS.OPEN_IN_N8N') }}
            </a>
          </div>
          <p
            v-if="event.body"
            class="mb-0 whitespace-pre-line text-body-main text-n-slate-12"
          >
            {{ event.body }}
          </p>
          <p
            v-if="event.text"
            class="mb-0 break-words line-clamp-4 text-body-main text-n-slate-11"
          >
            {{ readableReason(event.text) }}
          </p>
        </li>
      </ol>
      <p
        v-if="!events.length"
        class="mb-0 text-center text-body-main text-n-slate-11"
      >
        {{ t('SEQUENCE_REPORTS.TIMELINE.EMPTY') }}
      </p>
    </div>
  </SidePanel>
</template>
