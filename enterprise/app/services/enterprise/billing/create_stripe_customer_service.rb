class Enterprise::Billing::CreateStripeCustomerService
  pattr_initialize [:account!]

  DEFAULT_QUANTITY = 2

  def perform
    return if existing_subscription?

    customer_id = prepare_customer_id
    subscription = Stripe::Subscription.create(
      {
        customer: customer_id,
        items: [{ price: price_id, quantity: default_quantity }]
      }
    )
    account.assign_attributes(
      custom_attributes: (account.custom_attributes || {}).merge(
        stripe_customer_id: customer_id,
        stripe_price_id: subscription['plan']['id'],
        stripe_product_id: subscription['plan']['product'],
        plan_name: default_plan&.[]('name'),
        subscribed_quantity: subscription['quantity']
      ),
      limits: merge_plan_limits(default_plan)
    )
    account.status = 'active'
    account.save!
  end

  private

  def prepare_customer_id
    customer_id = account.custom_attributes['stripe_customer_id']
    if customer_id.blank?
      customer = Stripe::Customer.create({ name: account.name, email: billing_email })
      customer_id = customer.id
    end
    customer_id
  end

  def default_quantity
    default_plan['default_quantity'] || DEFAULT_QUANTITY
  end

  def billing_email
    account.administrators.first.email
  end

  def default_plan
    installation_config = InstallationConfig.find_by(name: 'CHATWOOT_CLOUD_PLANS')
    plans = installation_config&.value || []
    @default_plan ||= plans.first
  end

  def price_id
    price_ids = default_plan['price_ids']
    price_ids.first
  end

  def merge_plan_limits(plan)
    return account.limits if plan.blank?

    existing_limits = (account.limits || {}).with_indifferent_access
    plan_limits = (plan['limits'] || {}).transform_keys(&:to_s)

    existing_limits.merge(plan_limits).to_h
  end

  def existing_subscription?
    stripe_customer_id = account.custom_attributes['stripe_customer_id']
    return false if stripe_customer_id.blank?

    subscriptions = Stripe::Subscription.list(
      {
        customer: stripe_customer_id,
        status: 'active',
        limit: 1
      }
    )
    subscriptions.data.present?
  end
end
