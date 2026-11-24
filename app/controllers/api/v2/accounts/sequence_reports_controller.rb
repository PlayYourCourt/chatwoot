# Reports → Sequences: read-only views over the n8n SMS sequence engine's database (deploy/n8n/).
class Api::V2::Accounts::SequenceReportsController < Api::V1::Accounts::BaseController
  RESULTS_PER_PAGE = 25
  CONTACT_SEARCH_LIMIT = 500

  before_action :check_authorization
  before_action :ensure_sequences_configured
  before_action :ensure_flow_and_range, only: [:summary]

  def index
    render json: {
      flows: Sequences::Flow.order(:key).as_json(only: %i[key name status]),
      n8n_url: ENV.fetch('SEQUENCES_N8N_URL', nil)
    }
  end

  def summary
    render json: V2::Reports::SequenceSummaryBuilder.new(flow_key: permitted_params[:flow], range: range).build
  end

  def enrollments
    scope = filtered(Sequences::Enrollment.all, :enrolled_at).where(permitted_params.slice(:status, :exit_reason, :current_step).to_h.compact_blank)
    render_page(scope.order(enrolled_at: :desc))
  end

  def attempts
    scope = filtered(Sequences::EnrollAttempt.all, :attempted_at).where(permitted_params.slice(:outcome).to_h.compact_blank)
    render_page(scope.order(attempted_at: :desc))
  end

  def enrollment
    enrollment = Sequences::Enrollment.find(params[:id])
    message_logs = enrollment.message_logs.order(:sent_at).to_a
    conversations = conversation_display_ids(message_logs)
    render json: {
      enrollment: with_contacts([enrollment]).first,
      step_logs: enrollment.step_logs.order(:ran_at, :id).as_json,
      message_logs: message_logs.map { |log| log.as_json.merge('conversation_id' => conversations[log.chatwoot_message_id]) }
    }
  end

  private

  def check_authorization
    authorize :report, :view?
  end

  def ensure_sequences_configured
    head :not_found if ENV['SEQUENCES_DATABASE_URL'].blank?
  end

  def ensure_flow_and_range
    return if permitted_params[:flow].present? && permitted_params[:since].present? && permitted_params[:until].present?

    render_could_not_create_error('flow, since and until are required')
  end

  def permitted_params
    params.permit(:flow, :since, :until, :status, :exit_reason, :current_step, :outcome, :q, :page)
  end

  def range
    Time.zone.at(permitted_params[:since].to_i)..Time.zone.at(permitted_params[:until].to_i)
  end

  # A search looks across every flow and date; without one the flow and date range narrow the list.
  def filtered(scope, time_column)
    return searched(scope) if permitted_params[:q].present?

    scope = scope.where(flow_key: permitted_params[:flow]) if permitted_params[:flow].present?
    scope = scope.where(time_column => range) if permitted_params[:since].present? && permitted_params[:until].present?
    scope
  end

  # By the Chatwoot contact (name, email, phone) or by the number that was enrolled.
  def searched(scope)
    query = permitted_params[:q].strip
    contact_ids = Current.account.contacts.where(
      'name ILIKE :search OR email ILIKE :search OR phone_number ILIKE :search', search: "%#{query}%"
    ).limit(CONTACT_SEARCH_LIMIT).pluck(:id)
    scope.where(contact_id: contact_ids).or(scope.where(scope.arel_table[:phone].matches("%#{query}%")))
  end

  def render_page(scope)
    page = [permitted_params[:page].to_i, 1].max
    records = scope.offset((page - 1) * RESULTS_PER_PAGE).limit(RESULTS_PER_PAGE).to_a
    render json: { payload: with_contacts(records), meta: { count: scope.count, current_page: page, per_page: RESULTS_PER_PAGE } }
  end

  def with_contacts(records)
    contacts = Current.account.contacts.where(id: records.filter_map(&:contact_id)).index_by(&:id)
    records.map do |record|
      record.as_json.merge('contact' => contacts[record.contact_id]&.as_json(only: %i[id name email phone_number]))
    end
  end

  def conversation_display_ids(message_logs)
    Current.account.messages.where(id: message_logs.filter_map(&:chatwoot_message_id))
           .joins(:conversation).pluck('messages.id', 'conversations.display_id').to_h
  end
end
