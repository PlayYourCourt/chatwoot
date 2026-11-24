# Read-only base for the SMS sequence engine's database (deploy/n8n/): n8n owns every write, Chatwoot only reads
# it for Reports → Sequences, through SEQUENCES_DATABASE_URL (role seq_readonly).
class Sequences::Record < ActiveRecord::Base # rubocop:disable Rails/ApplicationRecord
  self.abstract_class = true

  establish_connection(ENV['SEQUENCES_DATABASE_URL']) if ENV['SEQUENCES_DATABASE_URL'].present?

  def readonly?
    true
  end
end
