class Enterprise::Billing::HandleStripeEventService
  CLOUD_PLANS_CONFIG = 'CHATWOOT_CLOUD_PLANS'.freeze

  def perform(event:)
    @event = event

    case @event.type
    when 'customer.subscription.updated', 'customer.subscription.created'
      process_subscription_updated
    when 'customer.subscription.deleted'
      process_subscription_deleted
    else
      Rails.logger.debug { "Unhandled event type: #{event.type}" }
    end
  end

  private

  def process_subscription_updated
    plan = find_plan(subscription['plan']['product']) if subscription['plan'].present?

    # skipping self hosted plan events
    return if plan.blank? || account.blank?

    update_account_attributes(subscription, plan)
    update_plan_features(plan)
    account.save!
    reset_metered_usage
  end

  def update_account_attributes(subscription, plan)
    # https://stripe.com/docs/api/subscriptions/object
    account.assign_attributes(
      custom_attributes: (account.custom_attributes || {}).merge(subscription_attributes(subscription, plan)),
      limits: merged_limits_for(plan)
    )
    account.status = subscription_active?(subscription) ? 'active' : 'suspended'
  end

  def process_subscription_deleted
    # skipping self hosted plan events
    return if account.blank?

    mark_account_as_suspended('canceled')
    disable_all_premium_features
    enable_account_manually_managed_features
    account.save!
    Enterprise::Billing::CreateStripeCustomerService.new(account: account).perform
  end

  def update_plan_features(plan)
    disable_all_premium_features
    enable_plan_specific_features(plan) unless default_plan?(plan)

    # Enable any manually managed features configured in internal_attributes
    enable_account_manually_managed_features
  end

  def disable_all_premium_features
    features = premium_features
    return if features.blank?

    account.disable_features(*features)
  end

  def reset_metered_usage
    account.reset_response_usage
    account.reset_evolution_usage if account.respond_to?(:reset_evolution_usage)
  end

  def enable_plan_specific_features(plan)
    features = plan_features(plan)
    return if features.blank?

    account.enable_features(*features)
  end

  def subscription
    @subscription ||= @event.data.object
  end

  def account
    @account ||= Account.where("custom_attributes->>'stripe_customer_id' = ?", subscription.customer).first
  end

  def find_plan(plan_id)
    cloud_plans.find { |config| Array(config['product_id']).include?(plan_id) }
  end

  def default_plan?(plan = nil)
    plan_name = plan&.[]('name') || account.custom_attributes['plan_name']
    plan_name.blank? || plan_name == default_plan_config['name']
  end

  def enable_account_manually_managed_features
    # Get manually managed features from internal attributes using the service
    service = Internal::Accounts::InternalAttributesService.new(account)
    features = service.manually_managed_features

    # Enable each feature
    account.enable_features(*features) if features.present?
  end

  def subscription_attributes(subscription, plan)
    {
      stripe_customer_id: subscription.customer,
      stripe_price_id: subscription['plan']['id'],
      stripe_product_id: subscription['plan']['product'],
      plan_name: plan['name'],
      subscribed_quantity: subscription['quantity'],
      subscription_status: subscription['status'],
      subscription_ends_on: Time.zone.at(subscription['current_period_end'])
    }
  end

  def merged_limits_for(plan)
    return account.limits if plan.blank?

    existing_limits = (account.limits || {}).with_indifferent_access
    plan_limits = plan_limits_for(plan)

    existing_limits.merge(plan_limits).to_h
  end

  def plan_limits_for(plan)
    limits = (plan['limits'] || {}).transform_keys(&:to_s)
    limits.default = nil
    limits
  end

  def subscription_active?(subscription)
    return false if subscription.blank?

    status = subscription['status']
    return false if status.blank?

    active_statuses = %w[active trialing past_due]
    return false unless active_statuses.include?(status)

    period_end = subscription['current_period_end']
    return true if period_end.blank?

    Time.zone.at(period_end) >= Time.zone.now
  end

  def premium_features
    configured = cloud_plans.flat_map { |plan| Array(plan['features']) }
    return configured.map(&:to_s).uniq if configured.present?

    []
  end

  def plan_features(plan)
    features = Array(plan&.[]('features'))
    return features.map(&:to_s) if features.present?

    []
  end

  def cloud_plans
    InstallationConfig.find_by(name: CLOUD_PLANS_CONFIG)&.value || []
  end

  def default_plan_config
    cloud_plans.first || {}
  end

  def mark_account_as_suspended(status)
    existing_attributes = (account.custom_attributes || {})
    attrs = existing_attributes.merge(
      'subscription_status' => status,
      'subscription_ends_on' => existing_attributes['subscription_ends_on'] || Time.zone.now
    )

    account.assign_attributes(custom_attributes: attrs)
    account.status = 'suspended'
  end
end
