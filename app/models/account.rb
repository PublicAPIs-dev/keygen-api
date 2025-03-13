# frozen_string_literal: true

class Account < ApplicationRecord
  include Keygen::EE::ProtectedMethods[:sso_organization_id=, :sso_organization_domains=, entitlements: %i[sso]]
  include Keygen::PortableClass
  include Welcomeable
  include Limitable
  include Orderable
  include Dirtyable
  include Pageable
  include Billable

  belongs_to :plan, optional: true, null_object: NullPlan.name
  has_one :billing, null_object: NullBilling.name
  has_many :environments, dependent: :destroy_async
  has_many :webhook_endpoints, dependent: :destroy_async
  has_many :webhook_events, dependent: :destroy_async
  has_many :request_logs, dependent: :destroy_async
  has_many :metrics, dependent: :destroy_async
  has_many :tokens, dependent: :destroy_async
  has_many :sessions, dependent: :destroy_async
  has_many :users, index_errors: true, dependent: :destroy_async
  has_many :second_factors, dependent: :destroy_async
  has_many :products, dependent: :destroy_async
  has_many :policies, dependent: :destroy_async
  has_many :keys, dependent: :destroy_async
  has_many :licenses, dependent: :destroy_async
  has_many :license_users, dependent: :destroy_async
  has_many :machines, dependent: :destroy_async
  has_many :machine_components, dependent: :destroy_async
  has_many :machine_processes, dependent: :destroy_async
  has_many :entitlements, dependent: :destroy_async
  has_many :policy_entitlements, dependent: :destroy_async
  has_many :license_entitlements, dependent: :destroy_async
  has_many :releases, dependent: :destroy_async
  has_many :release_engines, dependent: :destroy_async
  has_many :release_packages, dependent: :destroy_async
  has_many :release_manifests, dependent: :destroy_async
  has_many :release_descriptors, dependent: :destroy_async
  has_many :release_platforms, dependent: :destroy_async
  has_many :release_arches, dependent: :destroy_async
  has_many :release_filetypes, dependent: :destroy_async
  has_many :release_channels, dependent: :destroy_async
  has_many :release_entitlement_constraints, dependent: :destroy_async
  has_many :release_download_links, dependent: :destroy_async
  has_many :release_upgrade_links, dependent: :destroy_async
  has_many :release_upload_links, dependent: :destroy_async
  has_many :release_artifacts, dependent: :destroy_async
  has_many :event_logs, dependent: :destroy_async
  has_many :groups, dependent: :destroy_async
  has_many :group_owners, dependent: :destroy_async

  # FIXME(ezekg) roles should have an account_id foreign key
  has_many :environment_roles, through: :environments, source: :role
  has_many :product_roles, through: :products, source: :role
  has_many :license_roles, through: :licenses, source: :role
  has_many :user_roles, through: :users, source: :role
  has_many :environment_role_permissions, through: :environments, source: :role_permissions
  has_many :product_role_permissions, through: :products, source: :role_permissions
  has_many :license_role_permissions, through: :licenses, source: :role_permissions
  has_many :user_role_permissions, through: :users, source: :role_permissions
  has_many :token_permissions, through: :tokens
  has_many :group_permissions, through: :groups

  accepts_nested_attributes_for :users, limit: 10
  tracks_nested_attributes_for :users

  accepts_nested_attributes_for :billing
  tracks_nested_attributes_for :billing

  accepts_nested_attributes_for :plan
  tracks_nested_attributes_for :plan

  encrypts :ed25519_private_key
  encrypts :private_key
  encrypts :secret_key

  before_validation :set_founding_nested_users_to_admins!,
    if: :users_attributes_assigned?,
    on: :create

  before_create :set_autogenerated_registration_info!

  before_create -> { self.api_version ||= Current.api_version || DEFAULT_API_VERSION }
  before_create -> { self.backend ||= CF_ACCOUNT_ID ? 'R2' : 'S3' }
  before_create -> { self.slug = slug.downcase }

  before_create :generate_secret_key!
  before_create :generate_rsa_keys!
  before_create :generate_ed25519_keys!

  validates :plan,
    presence: true,
    if: -> { Keygen.multiplayer? }

  validates :users,
    length: { minimum: 1, message: "must have at least one admin user" }

  validates :slug,
    format: { with: /\A[a-z0-9][-a-z0-9]+\z/, message: "can only contain lowercase letters, numbers and dashes (but cannot start with dash)" },
    exclusion: { in: EXCLUDED_ALIASES, message: "is reserved" },
    uniqueness: { case_sensitive: false },
    length: { maximum: 255 },
    unless: -> { slug.nil? }

  validates :api_version,
    allow_nil: true,
    inclusion: {
      message: 'unsupported version',
      in: RequestMigrations.supported_versions,
    }

  validate on: %i[create], if: -> { id_before_type_cast.present? } do
    errors.add :id, :invalid, message: 'must be a valid UUID' if
      !UUID_RE.match?(id_before_type_cast)

    errors.add :id, :conflict, message: 'must not conflict with another account' if
      Account.exists?(id)
  end

  validate on: %i[create update] do
    clean_slug = "#{slug}".tr('-', '')

    errors.add :slug, :not_allowed, message: "cannot resemble a UUID" if
      clean_slug =~ UUID_RE
  end

  scope :active, -> (with_activity_from: 90.days.ago) {
    base = joins(:billing).where(billings: { state: %i[subscribed trialing pending] })

    new_accounts  = base.where('accounts.created_at > ?', with_activity_from)
    with_activity = base.where(<<~SQL.squish, with_activity_from)
      EXISTS (
        SELECT
          1
        FROM
          "event_logs"
        WHERE
          "event_logs"."account_id" = "accounts"."id" AND
          "event_logs"."created_at" > ?
        LIMIT
          1
      )
    SQL

    new_accounts.or(with_activity)
  }
  scope :paid, -> { joins(:plan, :billing).where(plan: Plan.paid, billings: { state: 'subscribed' }) }
  scope :free, -> { joins(:plan, :billing).where(plan: Plan.free, billings: { state: 'subscribed' }) }
  scope :ent,  -> { joins(:plan, :billing).where(plan: Plan.ent, billings: { state: 'subscribed' }) }
  scope :with_plan, -> (id) { where plan: id }

  after_commit :clear_cache!,
    on: %i[update destroy]

  def billing!
    raise Keygen::Error::NotFoundError.new(model: Billing.name) unless
      billing.present?

    billing
  end

  def email
    admins.first.email
  end

  # TODO(ezekg) Temp attributes for backwards compat during DSA/ECDSA deploy
  def private_key
    attrs = attributes

    case
    when attrs.key?("rsa_private_key")
      attrs["rsa_private_key"]
    when attrs.key?("private_key")
      attrs["private_key"]
    end
  end

  def private_key=(value)
    attrs = attributes

    case
    when attrs.key?("rsa_private_key")
      write_attribute :rsa_private_key, value
    when attrs.key?("private_key")
      write_attribute :private_key, value
    end
  end

  def public_key
    attrs = attributes

    case
    when attrs.key?("rsa_public_key")
      attrs["rsa_public_key"]
    when attrs.key?("public_key")
      attrs["public_key"]
    end
  end

  def public_key=(value)
    attrs = attributes

    case
    when attrs.key?("rsa_public_key")
      write_attribute :rsa_public_key, value
    when attrs.key?("public_key")
      write_attribute :public_key, value
    end
  end

  def self.cache_key(id)
    [:accounts, id, CACHE_KEY_VERSION].join ":"
  end

  def cache_key
    Account.cache_key id
  end

  def self.clear_cache!(id)
    key = Account.cache_key id

    Rails.cache.delete key
  end

  def clear_cache!
    Account.clear_cache! id
    Account.clear_cache! slug
  end

  def self.daily_request_count_cache_key_ts
    now = Time.current

    now.beginning_of_day.to_i
  end

  def self.daily_request_count_cache_key(id)
    [:req, :limits, :daily, id, daily_request_count_cache_key_ts].join ':'
  end

  def daily_request_count_cache_key
    Account.daily_request_count_cache_key id
  end

  def daily_request_count=(count)
    Rails.cache.write daily_request_count_cache_key, count, raw: true
  end

  def daily_request_count
    count = Rails.cache.read daily_request_count_cache_key, raw: true

    count.to_i
  end

  def daily_request_limit
    return 2_500 if billing&.trialing? && billing&.card.nil?

    plan&.max_reqs
  end

  def daily_request_limit_exceeded?
    return false if daily_request_limit.nil?

    daily_request_count > daily_request_limit
  end

  def active_licensed_user_count
    license_counts = licenses.left_outer_joins(:users)
                             .group('users.id')
                             .reorder('users.id NULLS FIRST')
                             .distinct
                             .active
                             .count

    # FIXME(ezekg) The nil key here is really weird, but that's what AR gives us for
    #              unassigned licenses i.e. those without a user.
    total_unassigned_licenses = license_counts[nil].to_i

    # We're counting a user with any amount of licenses as 1 "licensed user."
    total_assigned_licenses = license_counts.except(nil).count

    total_licensed_users =
      total_unassigned_licenses + total_assigned_licenses

    total_licensed_users
  end

  def trialing_or_free? = (billing.trialing? && billing.card.nil?) || plan.free?
  def paid?             = (billing.active? || billing.card.present?) && plan.paid?
  def free?             = plan.free?
  def ent?              = plan.ent?

  def protected?
    protected
  end

  def sso? = sso_organization_id?
  def sso_for?(email)
    return false if email.blank?

    _, domain = email.downcase.match(/([^@]+)@(.+)/)
                              .captures

    domain.in?(sso_organization_domains)
  end

  def status
    billing&.state&.upcase
  end

  def admins
    users.admins
  end

  def technical_contacts
    users.with_roles(:admin, :developer)
  end

  def self.associated_to?(association)
    associations = self.reflect_on_all_associations(:has_many)

    associations.any? { |r| r.name == association.to_sym }
  end

  def associated_to?(association)
    self.class.associated_to?(association)
  end

  private

  def set_founding_nested_users_to_admins!
    users.each do |user|
      next unless
        user.new_record?

      user.assign_attributes(
        role_attributes: { name: :admin },
      )
    end
  end

  def set_autogenerated_registration_info!
    parsed_email = users.first.parsed_email
    throw :abort if parsed_email.nil?

    user = parsed_email.fetch(:user)
    host = parsed_email.fetch(:host)

    autogen_slug = slug || host.parameterize.dasherize.downcase
    autogen_name = host

    # Generate an account slug using the email if the current domain is a public
    # email service or if an account with the domain already exists
    if PUBLIC_EMAIL_DOMAINS.include?(host)
      autogen_slug = user.parameterize.dasherize.downcase
      autogen_name = user
    end

    # FIXME(ezekg) Duplicate slug validation (name may be a UUID)
    if autogen_slug =~ UUID_RE
      errors.add :slug, :not_allowed, message: "cannot resemble a UUID"

      throw :abort
    end

    # Append a random string if slug is taken for public email service.
    # Otherwise, don't allow duplicate accounts for taken domains.
    if Account.exists?(slug: autogen_slug)
      if PUBLIC_EMAIL_DOMAINS.include?(host)
        autogen_slug += "-#{SecureRandom.hex(4)}"
      else
        errors.add :slug, :not_allowed, message: "already exists for this domain (please choose a different value or use account recovery)"

        throw :abort
      end
    end

    self.name = autogen_name unless name.present?
    self.slug = autogen_slug
  end

  def generate_secret_key!
    self.secret_key = SecureRandom.hex 64
  end
  alias_method :regenerate_secret_key!, :generate_secret_key!

  def generate_rsa_keys!
    priv = if private_key.nil?
             OpenSSL::PKey::RSA.generate RSA_KEY_SIZE
           else
             OpenSSL::PKey::RSA.new private_key
           end
    pub = priv.public_key

    # TODO(ezekg) Rename to rsa_private_key and rsa_public_key
    self.private_key = priv.to_pem
    self.public_key = pub.to_pem
  end
  alias_method :regenerate_rsa_keys!, :generate_rsa_keys!

  def generate_ed25519_keys!
    priv =
      if ed25519_private_key.present?
        Ed25519::SigningKey.new([ed25519_private_key].pack("H*"))
      else
        Ed25519::SigningKey.generate
      end
    pub = priv.verify_key

    self.ed25519_private_key = priv.to_bytes.unpack1("H*")
    self.ed25519_public_key = pub.to_bytes.unpack1("H*")
  end
  alias_method :regenerate_ed25519_keys!, :generate_ed25519_keys!
end
