// n8n prunes execution data after EXECUTIONS_DATA_MAX_AGE (720 hours, see deploy/.env.n8n.example); older
// "open in n8n" links would land on a missing run.
export const N8N_EXECUTION_RETENTION_DAYS = 30;

export const ENROLLMENT_STATUSES = ['active', 'completed', 'exited', 'held'];

export const ENROLLED_OUTCOME = 'enrolled';

export const PEOPLE_TABS = {
  ENROLLMENTS: 'enrollments',
  ATTEMPTS: 'attempts',
};

export const STATUS_COLOR_CLASSES = {
  active: 'bg-n-blue-3 text-n-blue-11',
  completed: 'bg-n-teal-3 text-n-teal-11',
  exited: 'bg-n-slate-3 text-n-slate-11',
  held: 'bg-n-amber-3 text-n-amber-11',
  enrolled: 'bg-n-teal-3 text-n-teal-11',
  sent: 'bg-n-teal-3 text-n-teal-11',
  deferred: 'bg-n-slate-3 text-n-slate-11',
  skipped: 'bg-n-slate-3 text-n-slate-11',
  pending: 'bg-n-slate-3 text-n-slate-11',
  resent: 'bg-n-blue-3 text-n-blue-11',
  failed: 'bg-n-ruby-3 text-n-ruby-11',
  unknown: 'bg-n-amber-3 text-n-amber-11',
};

export const DEFAULT_STATUS_COLOR_CLASS = 'bg-n-amber-3 text-n-amber-11';
