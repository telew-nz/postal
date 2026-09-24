# frozen_string_literal: true

module API
  module V2
    # Messages, their delivery history and the suppression list for a server.
    #
    # Messages do not live in the main database. Each server has its own message
    # database which is accessed through Postal::MessageDB so the actions here
    # work with plain hashes and lightweight objects rather than Active Record
    # models.
    class MessagesController < BaseController

      include ScopedToServer

      # The types of entry which can appear on the suppression list.
      SUPPRESSION_TYPES = ["recipient"].freeze

      # The filters which may be used when listing messages.
      MESSAGE_QUERY_PARAMS = [:scope, :to, :from, :status, :token, :message_id, :tag, :id, :spam, :before, :after, :order].freeze

      # The actions which operate on a single message.
      MESSAGE_ACTIONS = [:show, :deliveries, :activity, :spam_checks, :plain, :html, :headers, :attachments, :attachment, :download, :retry, :cancel_hold, :remove_from_queue].freeze

      rescue_from MessageQuery::TimeUndetermined, with: :render_time_undetermined_error

      before_action :load_message, only: MESSAGE_ACTIONS

      def index
        render_messages(MessageQuery.new(message_query_params))
      end

      # A shortcut for listing the messages which are currently being held.
      def held
        render_messages(MessageQuery.new(message_query_params, held: true))
      end

      def show
        render_data(MessageSerializer.new(message, detail: true).as_json)
      end

      def deliveries
        render_collection(DeliverySerializer.collection(message.deliveries.reverse))
      end

      def activity
        render_collection(ActivityEntrySerializer.collection(message.activity_entries.reverse))
      end

      def spam_checks
        checks = message.spam_checks.sort_by { |check| check["score"].to_f }.reverse
        render_collection(SpamCheckSerializer.collection(checks))
      end

      def plain
        render_data({ body: message.plain_body })
      end

      def html
        render_data({ body: message.html_body })
      end

      # The headers of the raw message. This action cannot be called "headers"
      # because that would shadow the headers method which ActionController::Metal
      # delegates to the response, and which send_data relies upon.
      def raw_headers
        render_data({ headers: message.headers })
      end

      def attachments
        render_data({ attachments: attachment_metadata })
      end

      # The binary content of one of the message's attachments. The attachment is
      # identified by its position in the list, which is the same convention the
      # web UI uses.
      def attachment
        index = params[:attachment].to_i
        if message.attachments.size > index
          attachment = message.attachments[index]
          send_data attachment.body, content_type: attachment.mime_type, disposition: "attachment", filename: attachment.filename
        else
          render_error(:not_found, "NotFound", "There is no attachment at position #{index} for this message.")
        end
      end

      # The raw RFC822 message as an .eml file.
      def download
        unless message.raw_message?
          render_error(:not_found, "NotFound", "We no longer have the raw message stored for this message.")
          return
        end

        send_data message.raw_message, filename: "Message-#{organization.permalink}-#{server.permalink}-#{message.id}.eml", content_type: "text/plain"
      end

      # Re-deliver a message. This mirrors the behaviour of the web UI: if the
      # message is already in the queue it is retried immediately, otherwise a
      # new queue entry is created.
      def retry
        unless message.raw_message?
          render_error(:unprocessable_entity, "MessageUnavailable", "This message is no longer available and cannot be retried.")
          return
        end

        if message.queued_message
          message.queued_message.retry_now
        else
          message.add_to_message_queue(manual: true)
        end

        render_data(MessageSerializer.new(message.reload).as_json)
      end

      def cancel_hold
        message.cancel_hold
        render_data(MessageSerializer.new(message.reload).as_json)
      end

      # Removing a message which is not in the queue is not an error. This action
      # is idempotent so that it can be retried safely by a client.
      def remove_from_queue
        queued_message = message.queued_message
        queued_message.destroy if queued_message && !queued_message.locked?
        render_no_content
      end

      def suppressions
        result = server.message_db.suppression_list.all_with_pagination(pagination_page, pagination_per_page)
        render_collection(SuppressionSerializer.collection(result[:records]), message_db_pagination_for(result, result[:page]))
      end

      def create_suppression
        type = params[:type].to_s
        address = params[:address].to_s
        if type.blank? || address.blank?
          render_error(:bad_request, "ParameterMissing", "A type and an address must be provided to add a suppression.")
          return
        end

        unless SUPPRESSION_TYPES.include?(type)
          render_error(:unprocessable_entity, "ValidationError", "The suppression could not be added.", ["Type must be one of: #{SUPPRESSION_TYPES.join(', ')}"])
          return
        end

        server.message_db.suppression_list.add(type, address, reason: params[:reason], days: suppression_days)
        suppression = server.message_db.suppression_list.get(type, address)
        render_created(SuppressionSerializer.new(suppression).as_json)
      end

      def destroy_suppression
        removed = server.message_db.suppression_list.remove(params[:suppression_type], params[:suppression_address])
        if removed
          render_no_content
        else
          render_error(:not_found, "NotFound", "There is no suppression for #{params[:suppression_address]} with the type #{params[:suppression_type]}.")
        end
      end

      private

      # The message which the request is about.
      #
      # @return [Postal::MessageDB::Message]
      def message
        @message ||= server.message_db.message(params[:id].to_i)
      end

      def load_message
        message
      end

      # Run a query and render the messages it returns.
      #
      # @param [MessageQuery] query
      # @return [void]
      def render_messages(query)
        result = server.message_db.messages_with_pagination(pagination_page, query.to_options(pagination_per_page))
        render_collection(MessageSerializer.collection(result[:records]), message_db_pagination_for(result, result[:page]))
      end

      # @return [ActionController::Parameters]
      def message_query_params
        params.permit(*MESSAGE_QUERY_PARAMS)
      end

      # @return [Array<Hash>]
      def attachment_metadata
        message.attachments.map do |attachment|
          {
            filename: attachment.filename,
            content_type: attachment.mime_type,
            size: attachment.body.to_s.bytesize
          }
        end
      end

      # The number of days which a suppression should be kept for. When this is
      # not provided the default configured for the installation is used.
      #
      # @return [Integer, nil]
      def suppression_days
        return nil if params[:days].blank?

        params[:days].to_i
      end

      def render_time_undetermined_error(exception)
        render_error(:unprocessable_entity, "TimeUndetermined", exception.message)
      end

    end
  end
end
