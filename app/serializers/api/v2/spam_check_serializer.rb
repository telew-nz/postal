# frozen_string_literal: true

module API
  module V2
    # Spam checks are returned from the message database as plain hashes.
    class SpamCheckSerializer < BaseSerializer

      def as_json(*)
        {
          id: attribute(:id),
          message_id: attribute(:message_id),
          code: attribute(:code),
          score: decimal(attribute(:score)),
          description: text(attribute(:description))
        }
      end

    end
  end
end
