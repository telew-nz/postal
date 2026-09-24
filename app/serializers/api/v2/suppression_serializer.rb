# frozen_string_literal: true

module API
  module V2
    # Suppressions are returned from the message database as plain hashes rather
    # than as objects so the values are read using the #attribute helper.
    class SuppressionSerializer < BaseSerializer

      def as_json(*)
        {
          id: attribute(:id),
          type: attribute(:type),
          address: attribute(:address),
          reason: attribute(:reason),
          timestamp: iso8601(attribute(:timestamp)),
          keep_until: iso8601(attribute(:keep_until)),
          expired: expired?
        }
      end

      private

      def expired?
        keep_until = attribute(:keep_until)
        return false if keep_until.nil?

        keep_until.to_f < Time.now.to_f
      end

    end
  end
end
