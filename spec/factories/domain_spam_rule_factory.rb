# frozen_string_literal: true

FactoryBot.define do
  factory :domain_spam_rule do
    association :domain

    kind { "blocklist" }
    match_type { "address" }
    sequence(:value) { |n| "spammer#{n}@example.com" }
    action { "reject" }
    enabled { true }

    trait :allowlist do
      kind { "allowlist" }
      action { "none" }
    end

    trait :domain_match do
      match_type { "domain" }
      value { "spamdomain.com" }
    end
  end
end
