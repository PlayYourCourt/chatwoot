class Api::V1::Accounts::Integrations::KlaviyoController < Api::V1::Accounts::Integrations::BaseController
  # Called by a Klaviyo Flow "Webhook" action. Finds or creates the contact, opens (or reuses) a
  # conversation on the given inbox and sends `content` as an outgoing message from that inbox.
  def outreach
    result = Klaviyo::OutreachService.new(account: Current.account, user: Current.user, params: permitted_params).perform
    render json: result
  end

  private

  def permitted_params
    params.permit(:email, :phone_number, :name, :inbox_id, :content, :flow_step, labels: [], custom_attributes: {})
  end
end
