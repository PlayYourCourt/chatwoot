class Sequences::Enrollment < Sequences::Record
  self.table_name = 'seq_enrollments'

  has_many :step_logs, class_name: 'Sequences::StepLog', dependent: nil
  has_many :message_logs, class_name: 'Sequences::MessageLog', dependent: nil

  # The cohort a report looks at: everyone who entered the flow in the range.
  scope :enrolled_in, ->(flow_key, range) { where(flow_key: flow_key, enrolled_at: range) }
end
