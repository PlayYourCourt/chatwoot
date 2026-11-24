import differenceInDays from 'date-fns/differenceInDays';
import format from 'date-fns/format';
import { N8N_EXECUTION_RETENTION_DAYS } from './constants';

const TIMESTAMP_FORMAT = 'MMM d, yyyy h:mm a';

export const formatTimestamp = value =>
  value ? format(new Date(value), TIMESTAMP_FORMAT) : '';

// Engine values are machine identifiers (prior_conversation, skipped_reentry, label:vip): shown as written,
// with underscores opened up.
export const humanize = value => String(value ?? '').replace(/_/g, ' ');

// A step's reason is either an engine identifier or the raw error of a failed send: the JSON n8n got back from
// the HTTP call, cut off at 500 characters (so it rarely parses). Show the identifier opened up, or the error's
// own message without the stack trace.
const ERROR_MESSAGE_PATTERN = /^\{"message":"((?:[^"\\]|\\.)*)"/;

export const readableReason = value => {
  const text = String(value ?? '');
  if (/^[\w:.-]+$/.test(text)) return humanize(text);
  const [, message] = text.match(ERROR_MESSAGE_PATTERN) || [];
  return message ? message.replace(/\\+"?/g, '') : text;
};

// The link to the n8n run that wrote a log row, or null when the row has none or n8n has pruned the run.
export const n8nExecutionUrl = (n8nUrl, record, timestamp) => {
  if (!n8nUrl || !record?.workflow_id || !record?.execution_id) return null;
  if (
    differenceInDays(new Date(), new Date(timestamp)) >=
    N8N_EXECUTION_RETENTION_DAYS
  ) {
    return null;
  }
  return `${n8nUrl.replace(/\/$/, '')}/workflow/${record.workflow_id}/executions/${record.execution_id}`;
};
