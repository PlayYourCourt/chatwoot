class Sequences::MessageLog < Sequences::Record
  self.table_name = 'seq_message_logs'

  belongs_to :enrollment, class_name: 'Sequences::Enrollment'
end
