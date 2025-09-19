class Enterprise::Api::V1::AccountsController < Api::BaseController
  include BillingHelper
  before_action :fetch_account
  before_action :check_authorization
  before_action :check_cloud_env, only: [:limits, :toggle_deletion]

  def subscription
    if stripe_customer_id.blank? && @account.custom_attributes['is_creating_customer'].blank?
      @account.update(custom_attributes: { is_creating_customer: true })
      Enterprise::CreateStripeCustomerJob.perform_later(@account)
    end
    head :no_content
  end

  def limits
    render json: {
      id: @account.id,
      limits: serialized_limits,
      subscription: subscription_payload,
      plan: plan_payload
    }, status: :ok
  end

  def checkout
    return create_stripe_billing_session(stripe_customer_id) if stripe_customer_id.present?

    render_invalid_billing_details
  end

  def toggle_deletion
    action_type = params[:action_type]

    case action_type
    when 'delete'
      mark_for_deletion
    when 'undelete'
      unmark_for_deletion
    else
      render json: { error: 'Invalid action_type. Must be either "delete" or "undelete"' }, status: :unprocessable_entity
    end
  end

  private

  def check_cloud_env
    render json: { error: 'Not found' }, status: :not_found unless ChatwootApp.chatwoot_cloud?
  end

  def serialized_limits
    usage_limits = @account.usage_limits

    {
      'conversation' => conversation_limits,
      'non_web_inboxes' => non_web_inbox_limits,
      'agents' => {
        'allowed' => usage_limits[:agents],
        'consumed' => agents(@account)
      },
      'captain' => usage_limits[:captain],
      'evolution' => usage_limits[:evolution]
    }.compact
  end

  def conversation_limits
    allowed = plan_limit_value(:conversation, default_plan?(@account) ? 500 : nil)
    return {} if allowed.blank?

    {
      'allowed' => allowed.to_i,
      'consumed' => conversations_this_month(@account)
    }
  end

  def non_web_inbox_limits
    allowed = plan_limit_value(:non_web_inboxes, default_plan?(@account) ? 0 : nil)
    return {} if allowed.blank?

    {
      'allowed' => allowed.to_i,
      'consumed' => non_web_inboxes(@account)
    }
  end

  def plan_limit_value(key, fallback = nil)
    limits = @account.limits || {}
    limit_value = limits[key.to_s]
    return limit_value if limit_value.present?

    fallback
  end

  def subscription_payload
    attributes = @account.custom_attributes || {}

    {
      plan: attributes['plan_name'],
      status: attributes['subscription_status'],
      quantity: attributes['subscribed_quantity'],
      ends_on: attributes['subscription_ends_on']
    }.compact
  end

  def plan_payload
    {
      name: subscription_payload[:plan],
      limits: @account.limits || {},
      features: @account.enabled_features.keys
    }
  end

  def fetch_account
    @account = current_user.accounts.find(params[:id])
    @current_account_user = @account.account_users.find_by(user_id: current_user.id)
  end

  def stripe_customer_id
    @account.custom_attributes['stripe_customer_id']
  end

  def mark_for_deletion
    reason = 'manual_deletion'

    if @account.mark_for_deletion(reason)
      render json: { message: 'Account marked for deletion' }, status: :ok
    else
      render json: { message: @account.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def unmark_for_deletion
    if @account.unmark_for_deletion
      render json: { message: 'Account unmarked for deletion' }, status: :ok
    else
      render json: { message: @account.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def render_invalid_billing_details
    render_could_not_create_error('Please subscribe to a plan before viewing the billing details')
  end

  def create_stripe_billing_session(customer_id)
    session = Enterprise::Billing::CreateSessionService.new.create_session(customer_id)
    render_redirect_url(session.url)
  end

  def render_redirect_url(redirect_url)
    render json: { redirect_url: redirect_url }
  end

  def pundit_user
    {
      user: current_user,
      account: @account,
      account_user: @current_account_user
    }
  end
end
