# Funnel of one SMS sequence flow for the people who enrolled in a date range: how many tried to enter, how many
# reached each step, what was sent there and why people left. Reads the n8n engine's seq database.
class V2::Reports::SequenceSummaryBuilder
  OPEN_STATUSES = %w[active held].freeze
  FAILED_SENDS = %w[failed unknown].freeze
  RECENT_ERRORS = 20

  def initialize(flow_key:, range:)
    @flow_key = flow_key
    @range = range
  end

  def build
    {
      attempts: attempts.group(:outcome).count,
      enrollments: cohort.group(:status).count,
      steps: steps,
      exits: exits,
      errors: errors
    }
  end

  private

  def attempts
    Sequences::EnrollAttempt.where(flow_key: @flow_key, attempted_at: @range)
  end

  def cohort
    Sequences::Enrollment.enrolled_in(@flow_key, @range)
  end

  def step_logs
    Sequences::StepLog.where(enrollment_id: cohort.select(:id))
  end

  def steps
    logged = step_logs.group(:step).distinct.count(:enrollment_id)
    deferred = step_logs.where(outcome: 'deferred').group(:step).distinct.count(:enrollment_id)
    messages = Sequences::MessageLog.where(enrollment_id: cohort.select(:id)).group(:step, :status).count
    open = cohort.where(status: OPEN_STATUSES).group(:current_step, :status).count
    exited = cohort.where(status: 'exited').group(:current_step).count

    step_names(logged, open).map do |step|
      {
        step: step,
        reached: logged[step].to_i + not_yet_run(step),
        sent: messages[[step, 'sent']].to_i,
        failed: FAILED_SENDS.sum { |status| messages[[step, status]].to_i },
        deferred: deferred[step].to_i,
        waiting: open[[step, 'active']].to_i,
        held: open[[step, 'held']].to_i,
        exited: exited[step].to_i
      }
    end
  end

  # Step names are the flow's own labels ("1", "2", ...): numeric ones in order, anything else after them.
  def step_names(logged, open)
    (logged.keys + open.keys.map(&:first)).uniq.sort_by { |step| [Integer(step, exception: false) || Float::INFINITY, step] }
  end

  # People parked on a step the engine has not run for them yet (no log row at that step so far).
  def not_yet_run(step)
    cohort.where(status: OPEN_STATUSES, current_step: step)
          .where.not(id: step_logs.where(step: step).select(:enrollment_id))
          .count
  end

  def exits
    cohort.where(status: 'exited').group(:current_step, :exit_reason).count.map do |(step, reason), count|
      { step: step, reason: reason, count: count }
    end
  end

  def errors
    Sequences::EngineError.where(occurred_at: @range).order(occurred_at: :desc).limit(RECENT_ERRORS)
                          .as_json(only: %i[id workflow_id workflow_name execution_id node message occurred_at])
  end
end
