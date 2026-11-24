# One row per call to the enroll API or the enroll-<flow> label, refused ones included.
class Sequences::EnrollAttempt < Sequences::Record
  self.table_name = 'seq_enroll_attempts'
end
