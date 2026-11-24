class Sequences::StepLog < Sequences::Record
  self.table_name = 'seq_step_logs'

  belongs_to :enrollment, class_name: 'Sequences::Enrollment'
end
