require 'rails_helper'

RSpec.describe 'Enterprise Billing APIs', type: :request do
  let(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:agent) { create(:user, account: account, role: :agent) }

  describe 'POST /enterprise/api/v1/accounts/{account.id}/subscription' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/enterprise/api/v1/accounts/#{account.id}/subscription", as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      context 'when it is an agent' do
        it 'returns unauthorized' do
          post "/enterprise/api/v1/accounts/#{account.id}/subscription",
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unauthorized)
        end
      end

      context 'when it is an admin' do
        it 'enqueues a job' do
          expect do
            post "/enterprise/api/v1/accounts/#{account.id}/subscription",
                 headers: admin.create_new_auth_token,
                 as: :json
          end.to have_enqueued_job(Enterprise::CreateStripeCustomerJob).with(account)
          expect(account.reload.custom_attributes).to eq({ 'is_creating_customer': true }.with_indifferent_access)
        end

        it 'does not enqueue a job if a job is already enqueued' do
          account.update!(custom_attributes: { is_creating_customer: true })

          expect do
            post "/enterprise/api/v1/accounts/#{account.id}/subscription",
                 headers: admin.create_new_auth_token,
                 as: :json
          end.not_to have_enqueued_job(Enterprise::CreateStripeCustomerJob).with(account)
        end

        it 'does not enqueues a job if customer id is present' do
          account.update!(custom_attributes: { 'stripe_customer_id': 'cus_random_string' })

          expect do
            post "/enterprise/api/v1/accounts/#{account.id}/subscription",
                 headers: admin.create_new_auth_token,
                 as: :json
          end.not_to have_enqueued_job(Enterprise::CreateStripeCustomerJob).with(account)
        end
      end
    end
  end

  describe 'POST /enterprise/api/v1/accounts/{account.id}/checkout' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/enterprise/api/v1/accounts/#{account.id}/checkout", as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      context 'when it is an agent' do
        it 'returns unauthorized' do
          post "/enterprise/api/v1/accounts/#{account.id}/checkout",
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unauthorized)
        end
      end

      context 'when it is an admin and the stripe customer id is not present' do
        it 'returns error' do
          post "/enterprise/api/v1/accounts/#{account.id}/checkout",
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_entity)
          json_response = JSON.parse(response.body)
          expect(json_response['error']).to eq('Please subscribe to a plan before viewing the billing details')
        end
      end

      context 'when it is an admin and the stripe customer is present' do
        it 'calls create session' do
          account.update!(custom_attributes: { 'stripe_customer_id': 'cus_random_string' })

          create_session_service = double
          allow(Enterprise::Billing::CreateSessionService).to receive(:new).and_return(create_session_service)
          allow(create_session_service).to receive(:create_session).and_return(create_session_service)
          allow(create_session_service).to receive(:url).and_return('https://billing.stripe.com/random_string')

          post "/enterprise/api/v1/accounts/#{account.id}/checkout",
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:success)
          json_response = JSON.parse(response.body)
          expect(json_response['redirect_url']).to eq('https://billing.stripe.com/random_string')
        end
      end
    end
  end

  describe 'GET /enterprise/api/v1/accounts/{account.id}/limits' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/enterprise/api/v1/accounts/#{account.id}/limits", as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    let(:default_plan_limits) do
      {
        'conversation' => 500,
        'non_web_inboxes' => 0,
        'agents' => 2,
        'captain_documents' => 0,
        'captain_responses' => 0,
        'evolution_sessions' => 0
      }
    end
    let(:cloud_plans) do
      [
        {
          'name' => 'Hacker',
          'product_id' => ['plan_id_hacker'],
          'price_ids' => ['price_hacker'],
          'features' => [],
          'limits' => default_plan_limits
        },
        {
          'name' => 'Startups',
          'product_id' => ['plan_id_startups'],
          'price_ids' => ['price_startups'],
          'features' => ['help_center'],
          'limits' => {
            'conversation' => 1000,
            'non_web_inboxes' => 3,
            'agents' => 5,
            'captain_documents' => 10,
            'captain_responses' => 100,
            'evolution_sessions' => 20
          }
        }
      ]
    end

    context 'when it is an authenticated user' do
      before do
        InstallationConfig.where(name: 'DEPLOYMENT_ENV').first_or_create(value: 'cloud')
        InstallationConfig.where(name: 'CHATWOOT_CLOUD_PLANS').first_or_create(value: cloud_plans)
        account.update!(limits: default_plan_limits)
      end

      context 'when it is an agent' do
        it 'returns unauthorized' do
          get "/enterprise/api/v1/accounts/#{account.id}/limits",
              headers: agent.create_new_auth_token,
              as: :json

          expect(response).to have_http_status(:success)
          json_response = JSON.parse(response.body)
          expect(json_response['id']).to eq(account.id)
          expect(json_response['limits']).to eq(
            {
              'conversation' => {
                'allowed' => 500,
                'consumed' => 0
              },
              'non_web_inboxes' => {
                'allowed' => 0,
                'consumed' => 0
              },
              'agents' => {
                'allowed' => 2,
                'consumed' => 2
              },
              'captain' => {
                'documents' => { 'total_count' => 0, 'current_available' => 0, 'consumed' => 0 },
                'responses' => { 'total_count' => 0, 'current_available' => 0, 'consumed' => 0 }
              },
              'evolution' => {
                'sessions' => { 'total_count' => 0, 'current_available' => 0, 'consumed' => 0 }
              }
            }
          )
          expect(json_response['subscription']).to eq({})
          expect(json_response['plan']).to eq({ 'name' => nil, 'limits' => default_plan_limits, 'features' => account.enabled_features.keys })
        end
      end

      context 'when it is an admin' do
        before do
          create(:conversation, account: account)
          create(:channel_api, account: account)
          InstallationConfig.where(name: 'DEPLOYMENT_ENV').first_or_create(value: 'cloud')
          InstallationConfig.where(name: 'CHATWOOT_CLOUD_PLANS').first_or_create(value: [{ 'name': 'Hacker' }])
        end

        it 'returns the limits if the plan is default' do
          account.update!(custom_attributes: { plan_name: 'Hacker' })
          get "/enterprise/api/v1/accounts/#{account.id}/limits",
              headers: admin.create_new_auth_token,
              as: :json

          expected_response = {
            'id' => account.id,
            'limits' => {
              'conversation' => {
                'allowed' => 500,
                'consumed' => 1
              },
              'non_web_inboxes' => {
                'allowed' => 0,
                'consumed' => 1
              },
              'agents' => {
                'allowed' => 2,
                'consumed' => 2
              },
              'captain' => {
                'documents' => { 'total_count' => 0, 'current_available' => 0, 'consumed' => 0 },
                'responses' => { 'total_count' => 0, 'current_available' => 0, 'consumed' => 0 }
              },
              'evolution' => {
                'sessions' => { 'total_count' => 0, 'current_available' => 0, 'consumed' => 0 }
              }
            },
            'subscription' => { 'plan' => 'Hacker' },
            'plan' => {
              'name' => 'Hacker',
              'limits' => default_plan_limits,
              'features' => account.enabled_features.keys
            }
          }

          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)).to eq(expected_response)
        end

        it 'returns nil if the plan is not default' do
          account.update!(custom_attributes: { plan_name: 'Startups' })
          account.update!(limits: cloud_plans.second['limits'])
          get "/enterprise/api/v1/accounts/#{account.id}/limits",
              headers: admin.create_new_auth_token,
              as: :json

          expected_response = {
            'id' => account.id,
            'limits' => {
              'agents' => {
                'allowed' => account.usage_limits[:agents],
                'consumed' => account.users.count
              },
              'conversation' => {},
              'captain' => {
                'documents' => {
                  'total_count' => cloud_plans.second['limits']['captain_documents'],
                  'current_available' => cloud_plans.second['limits']['captain_documents'],
                  'consumed' => 0
                },
                'responses' => {
                  'total_count' => cloud_plans.second['limits']['captain_responses'],
                  'current_available' => cloud_plans.second['limits']['captain_responses'],
                  'consumed' => 0
                }
              },
              'non_web_inboxes' => {},
              'evolution' => {
                'sessions' => {
                  'total_count' => cloud_plans.second['limits']['evolution_sessions'],
                  'current_available' => cloud_plans.second['limits']['evolution_sessions'],
                  'consumed' => 0
                }
              }
            },
            'subscription' => { 'plan' => 'Startups' },
            'plan' => {
              'name' => 'Startups',
              'limits' => cloud_plans.second['limits'],
              'features' => account.enabled_features.keys
            }
          }

          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)).to eq(expected_response)
        end

        it 'returns limits if a plan is not configured' do
          account.update!(limits: {})
          get "/enterprise/api/v1/accounts/#{account.id}/limits",
              headers: admin.create_new_auth_token,
              as: :json

          expected_response = {
            'id' => account.id,
            'limits' => {
              'conversation' => {
                'allowed' => 500,
                'consumed' => 1
              },
              'non_web_inboxes' => {
                'allowed' => 0,
                'consumed' => 1
              },
              'agents' => {
                'allowed' => 2,
                'consumed' => 2
              },
              'captain' => {
                'documents' => { 'total_count' => ChatwootApp.max_limit, 'current_available' => ChatwootApp.max_limit, 'consumed' => 0 },
                'responses' => { 'total_count' => ChatwootApp.max_limit, 'current_available' => ChatwootApp.max_limit, 'consumed' => 0 }
              },
              'evolution' => {
                'sessions' => { 'total_count' => ChatwootApp.max_limit, 'current_available' => ChatwootApp.max_limit, 'consumed' => 0 }
              }
            },
            'subscription' => {},
            'plan' => {
              'name' => nil,
              'limits' => {},
              'features' => account.enabled_features.keys
            }
          }
          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)).to eq(expected_response)
        end
      end
    end
  end

  describe 'POST /enterprise/api/v1/accounts/{account.id}/toggle_deletion' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/enterprise/api/v1/accounts/#{account.id}/toggle_deletion", as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      context 'when it is an agent' do
        it 'returns unauthorized' do
          post "/enterprise/api/v1/accounts/#{account.id}/toggle_deletion",
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unauthorized)
        end
      end

      context 'when deployment environment is not cloud' do
        before do
          # Set deployment environment to something other than cloud
          InstallationConfig.where(name: 'DEPLOYMENT_ENV').first_or_create(value: 'self_hosted')
        end

        it 'returns not found' do
          post "/enterprise/api/v1/accounts/#{account.id}/toggle_deletion",
               headers: admin.create_new_auth_token,
               params: { action_type: 'delete' },
               as: :json

          expect(response).to have_http_status(:not_found)
          expect(JSON.parse(response.body)['error']).to eq('Not found')
        end
      end

      context 'when it is an admin' do
        before do
          # Create the installation config for cloud environment
          InstallationConfig.where(name: 'DEPLOYMENT_ENV').first_or_create(value: 'cloud')
        end

        it 'marks the account for deletion when action is delete' do
          post "/enterprise/api/v1/accounts/#{account.id}/toggle_deletion",
               headers: admin.create_new_auth_token,
               params: { action_type: 'delete' },
               as: :json

          expect(response).to have_http_status(:ok)
          expect(account.reload.custom_attributes['marked_for_deletion_at']).to be_present
          expect(account.custom_attributes['marked_for_deletion_reason']).to eq('manual_deletion')
        end

        it 'unmarks the account for deletion when action is undelete' do
          # First mark the account for deletion
          account.update!(
            custom_attributes: {
              'marked_for_deletion_at' => 7.days.from_now.iso8601,
              'marked_for_deletion_reason' => 'manual_deletion'
            }
          )

          post "/enterprise/api/v1/accounts/#{account.id}/toggle_deletion",
               headers: admin.create_new_auth_token,
               params: { action_type: 'undelete' },
               as: :json

          expect(response).to have_http_status(:ok)
          expect(account.reload.custom_attributes['marked_for_deletion_at']).to be_nil
          expect(account.custom_attributes['marked_for_deletion_reason']).to be_nil
        end

        it 'returns error for invalid action' do
          post "/enterprise/api/v1/accounts/#{account.id}/toggle_deletion",
               headers: admin.create_new_auth_token,
               params: { action_type: 'invalid' },
               as: :json

          expect(response).to have_http_status(:unprocessable_entity)
          expect(JSON.parse(response.body)['error']).to include('Invalid action_type')
        end

        it 'returns error when action parameter is missing' do
          post "/enterprise/api/v1/accounts/#{account.id}/toggle_deletion",
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_entity)
          expect(JSON.parse(response.body)['error']).to include('Invalid action_type')
        end
      end
    end
  end
end
