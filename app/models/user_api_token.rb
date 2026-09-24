# frozen_string_literal: true

# == Schema Information
#
# Table name: user_api_tokens
#
#  id           :integer          not null, primary key
#  expires_at   :datetime
#  key          :string(255)
#  key_prefix   :string(255)
#  last_used_at :datetime
#  name         :string(255)
#  revoked_at   :datetime
#  uuid         :string(255)
#  created_at   :datetime
#  updated_at   :datetime
#  user_id      :integer
#
# Indexes
#
#  index_user_api_tokens_on_key      (key)
#  index_user_api_tokens_on_user_id  (user_id)
#  index_user_api_tokens_on_uuid     (uuid)
#

class UserAPIToken < ApplicationRecord

  include HasUUID

  # The prefix applied to all generated tokens so that they can be easily
  # identified in logs and by secret scanners.
  KEY_PREFIX = "pst_"

  # The number of random characters in a generated token (excluding the prefix).
  KEY_LENGTH = 32

  # The number of characters of the plain key which are stored to allow a
  # token to be identified by a user without revealing the token itself.
  KEY_PREVIEW_LENGTH = 8

  belongs_to :user

  validates :name, presence: true
  validates :key, presence: true, uniqueness: { case_sensitive: false }

  before_validation :generate_key

  # The plain text key is only available on the object which generated it.
  # It is never persisted so it cannot be retrieved after the record has
  # been saved.
  attr_reader :plain_key

  # Return the SHA-256 digest for a plain text key. Tokens have sufficient
  # entropy that a fast digest is appropriate here and it allows a token to
  # be looked up with a single indexed query.
  #
  # @param [String] value the plain text key
  #
  # @return [String] the digest which is stored in the database
  def self.hash_key(value)
    Digest::SHA256.hexdigest(value.to_s)
  end

  # Find the token which matches the provided plain text key. Only tokens
  # which have not been revoked and have not expired will be returned.
  #
  # @param [String] value the plain text key
  #
  # @return [UserAPIToken, nil] the matching token
  def self.authenticate(value)
    return nil if value.blank?

    active.find_by(key: hash_key(value))
  end

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.now) }

  # Record that this token has just been used to authenticate a request.
  #
  # @return [void]
  def use
    update_column(:last_used_at, Time.now)
  end

  # Permanently disable this token. Revoking is preferred to destroying so
  # that a record of the token remains for auditing purposes.
  #
  # @return [UserAPIToken]
  def revoke!
    update!(revoked_at: Time.now)
    self
  end

  def revoked?
    revoked_at.present?
  end

  def expired?
    expires_at.present? && expires_at <= Time.now
  end

  def active?
    !revoked? && !expired?
  end

  private

  def generate_key
    return if persisted?
    return if key.present?

    @plain_key = KEY_PREFIX + SecureRandom.alphanumeric(KEY_LENGTH)
    self.key = self.class.hash_key(@plain_key)
    self.key_prefix = @plain_key[0, KEY_PREVIEW_LENGTH]
  end

end
