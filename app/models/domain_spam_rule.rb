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
  MATCH_TYPES = %w[address domain subject].freeze
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

  def subject?
    match_type == "subject"
  end

  # Convert the rule's value (a wildcard pattern) into a regex source fragment.
  # `*` matches any sequence, `?` any single character; everything else is
  # escaped so the pattern is treated literally. Unanchored, so it matches a
  # substring of the subject, and case-insensitive at match time.
  def subject_regex_source
    Regexp.escape(value.to_s).gsub(/\\\*/, ".*").gsub(/\\\?/, ".")
  end

  # Does this subject rule match the given subject line?
  def matches_subject?(subject)
    return false if subject.blank?

    @subject_regex ||= Regexp.new(subject_regex_source, Regexp::IGNORECASE)
    @subject_regex.match?(subject)
  end

  # Build a single combined regex for a set of subject rules (all of the same
  # domain/kind). Testing this once is cheaper than testing each rule's regex
  # individually, which is the common hot path during message processing. Returns
  # nil when there are no subject rules.
  def self.combined_subject_regex(rules)
    sources = rules.filter_map { |rule| rule.subject_regex_source if rule.subject? }
    return nil if sources.empty?

    Regexp.new("(?:#{sources.join('|')})", Regexp::IGNORECASE)
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
