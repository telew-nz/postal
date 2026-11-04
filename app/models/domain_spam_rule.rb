# frozen_string_literal: true

# == Schema Information
#
# Table name: domain_spam_rules
#
#  id         :integer          not null, primary key
#  uuid       :string(255)
#  domain_id  :integer
#  kind       :string(255)      not null
#  match_type :string(255)      not null
#  value      :string(255)      not null
#  action     :string(255)      not null
#  enabled    :boolean          default(TRUE)
#  created_at :datetime
#  updated_at :datetime
#

class DomainSpamRule < ApplicationRecord

  include HasUUID

  belongs_to :domain

  KINDS = %w[allowlist blocklist].freeze
  MATCH_TYPES = %w[address domain].freeze
  ACTIONS = %w[reject mark_spam add_header none].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :match_type, inclusion: { in: MATCH_TYPES }
  validates :action, inclusion: { in: ACTIONS }, if: -> { blocklist? }
  validates :value, presence: true
  validates :value, format: { with: /\A[^@\s]+@[^@\s]+\z/ }, if: -> { match_type == "address" }
  validates :value, format: { with: /\A[a-z0-9\-.]+\z/ }, if: -> { match_type == "domain" }

  # A single rule per (domain, kind, match_type, value) — the same sender/domain
  # cannot be both blocked and allowed ambiguously, and upserts stay idempotent.
  validates :value, uniqueness: { scope: [:domain_id, :kind, :match_type], case_sensitive: false }

  def allowlist?
    kind == "allowlist"
  end

  def blocklist?
    kind == "blocklist"
  end

  # Does this rule match the given return-path sender (envelope) or From header?
  # address rules match the full address; domain rules match the registered part.
  def matches?(address)
    addr = address.to_s.downcase
    case match_type
    when "address"
      addr == value.to_s.downcase
    when "domain"
      value.to_s.downcase == addr.split("@").last.to_s.downcase
    else
      false
    end
  end

  def description
    "#{kind}/#{match_type}:#{value} (#{action})"
  end

  def as_json(*)
    {
      uuid: uuid,
      domain_id: domain_id,
      kind: kind,
      match_type: match_type,
      value: value,
      action: action,
      enabled: enabled,
      created_at: created_at&.iso8601,
      updated_at: updated_at&.iso8601
    }
  end

end
