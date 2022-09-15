# frozen_string_literal: true

FactoryBot.define do
  factory :entitlement do
    # Prevent duplicates due to cyclic entitlement codes below. Attempting
    # to insert duplicate codes would fail, and this prevents that.
    initialize_with { Entitlement.find_or_initialize_by(code:) }

    # Our entitlement codes cycle in sets of 10, so we can do things like
    # constrain a release with 10 entitlements via the :with_constraints
    # trait, and subsequently entitle a license with the same 10
    # entitlements via the :with_entitlements trait.
    sequence :code, %w[ALPHA BRAVO CHARLIE DELTA ECHO FOXTROT GOLF HOTEL INDIA JULIETT].cycle
    name { code.humanize }
  end
end
