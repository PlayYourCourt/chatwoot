# A failed n8n execution, recorded by the engine's error handler workflow.
class Sequences::EngineError < Sequences::Record
  self.table_name = 'seq_errors'
end
