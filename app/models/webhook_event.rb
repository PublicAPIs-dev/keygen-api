class WebhookEvent < ApplicationRecord
  include Idempotentable
  include Limitable
  include Pageable

  belongs_to :account

  validates :account, presence: { message: "must exist" }
  validates :endpoint, url: true, presence: true

  scope :events, -> (*events) { where event: events }

  def status
    Sidekiq::Status.status(jid) || :unavailable rescue :queued
  end
end

# == Schema Information
#
# Table name: webhook_events
#
#  id                :uuid             not null, primary key
#  payload           :text
#  jid               :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  endpoint          :string
#  account_id        :uuid
#  idempotency_token :string
#  event             :string
#
# Indexes
#
#  index_webhook_events_on_created_at_and_account_id  (created_at,account_id)
#  index_webhook_events_on_created_at_and_id          (created_at,id) UNIQUE
#  index_webhook_events_on_created_at_and_jid         (created_at,jid)
#  index_webhook_events_on_id                         (id) UNIQUE
#  index_webhook_events_on_idempotency_token          (idempotency_token)
#
