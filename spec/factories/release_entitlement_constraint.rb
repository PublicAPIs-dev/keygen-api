# frozen_string_literal: true

FactoryBot.define do
  factory :release_entitlement_constraint, aliases: %i[constraint] do
    # Prevent duplicates due to cyclic entitlement codes.
    initialize_with do
      ReleaseEntitlementConstraint.find_by(entitlement_id: entitlement&.id, release_id: release&.id) ||
        new(**attributes.reject { NIL_ENVIRONMENT == _2 })
    end

    account     { nil }
    environment { NIL_ENVIRONMENT }
    entitlement { build(:entitlement, account:, environment:) }
    release     { nil }

    trait :in_isolated_environment do
      environment { build(:environment, :isolated, account:) }
    end

    trait :isolated do
      in_isolated_environment
    end

    trait :in_shared_environment do
      environment { build(:environment, :shared, account:) }
    end

    trait :shared do
      in_shared_environment
    end

    trait :in_nil_environment do
      environment { nil }
    end

    trait :global do
      in_nil_environment
    end
  end
end
