<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  BaseTable,
  BaseTableRow,
  BaseTableCell,
} from 'dashboard/components-next/table';
import { formatTimestamp, n8nExecutionUrl } from './helpers';

defineProps({
  errors: {
    type: Array,
    default: () => [],
  },
  n8nUrl: {
    type: String,
    default: '',
  },
});

const { t } = useI18n();

const headers = computed(() => [
  t('SEQUENCE_REPORTS.ERRORS.TIME'),
  t('SEQUENCE_REPORTS.ERRORS.WORKFLOW'),
  t('SEQUENCE_REPORTS.ERRORS.NODE'),
  t('SEQUENCE_REPORTS.ERRORS.MESSAGE'),
  '',
]);
</script>

<template>
  <section class="flex flex-col gap-2">
    <h3 class="text-heading-2 text-n-slate-12">
      {{ t('SEQUENCE_REPORTS.ERRORS.TITLE') }}
    </h3>
    <BaseTable :headers="headers" :items="errors">
      <template #row="{ items }">
        <BaseTableRow v-for="item in items" :key="item.id" :item="item">
          <BaseTableCell>
            <span class="whitespace-nowrap">
              {{ formatTimestamp(item.occurred_at) }}
            </span>
          </BaseTableCell>
          <BaseTableCell>{{ item.workflow_name }}</BaseTableCell>
          <BaseTableCell>{{ item.node }}</BaseTableCell>
          <BaseTableCell>
            <span class="line-clamp-2 text-n-ruby-11">{{ item.message }}</span>
          </BaseTableCell>
          <BaseTableCell align="end">
            <a
              v-if="n8nExecutionUrl(n8nUrl, item, item.occurred_at)"
              :href="n8nExecutionUrl(n8nUrl, item, item.occurred_at)"
              target="_blank"
              rel="noopener noreferrer"
              class="whitespace-nowrap text-n-blue-11 hover:underline"
            >
              {{ t('SEQUENCE_REPORTS.OPEN_IN_N8N') }}
            </a>
          </BaseTableCell>
        </BaseTableRow>
      </template>
    </BaseTable>
  </section>
</template>
