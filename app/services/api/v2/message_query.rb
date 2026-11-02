# frozen_string_literal: true

module API
  module V2
    # Builds the query options which are consumed by the message database from the
    # structured parameters provided to the messages endpoints.
    #
    # This deliberately does not reuse the query language which the web UI
    # supports. The web UI persists its queries into the Rails session which
    # makes them stateful, and it parses a freeform string which is awkward to
    # describe in an API specification. The management API is stateless so every
    # request must fully describe what it wants.
    class MessageQuery

      # Raised when a time filter cannot be parsed. This is rescued by the
      # messages controller and rendered as a 422.
      class TimeUndetermined < Postal::Error; end

      # The scopes which messages can be filtered by.
      SCOPES = %w[outgoing incoming].freeze

      # The values which are treated as true for boolean filters.
      TRUE_VALUES = %w[true yes y 1 t].freeze

      def initialize(params, held: false)
        @params = params || {}
        @held = held
      end

      # Are we only interested in messages which are currently held?
      #
      # @return [Boolean]
      def held?
        @held
      end

      # The options which should be passed to the message database.
      #
      # @param [Integer, nil] per_page the number of messages to return
      # @return [Hash]
      def to_options(per_page = nil)
        options = held? ? { where: { held: true } } : filtered_options
        options[:per_page] = per_page if per_page
        options
      end

      private

      def filtered_options
        options = { where: { scope: scope, spam: false }, order: :timestamp, direction: direction }
        where = options[:where]

        where[:rcpt_to] = @params[:to] if @params[:to].present?
        where[:mail_from] = @params[:from] if @params[:from].present?
        where[:status] = @params[:status] if @params[:status].present?
        where[:token] = @params[:token] if @params[:token].present?

        if @params[:message_id].present?
          where[:message_id] = @params[:message_id]
          where.delete(:spam)
          where.delete(:scope)
        end

        where[:tag] = @params[:tag] if @params[:tag].present?
        where[:id] = @params[:id] if @params[:id].present?
        where[:spam] = true if truthy?(@params[:spam])

        timestamp = timestamp_filter
        where[:timestamp] = timestamp if timestamp

        options
      end

      # The scope to filter by. Anything which is not a valid scope is treated as
      # outgoing which is the most common case.
      #
      # @return [String]
      def scope
        SCOPES.include?(@params[:scope].to_s) ? @params[:scope].to_s : "outgoing"
      end

      # @return [String]
      def direction
        @params[:order].to_s == "oldest-first" ? "asc" : "desc"
      end

      # @return [Hash, nil]
      def timestamp_filter
        return nil if @params[:before].blank? && @params[:after].blank?

        timestamp = {}
        timestamp[:less_than] = parse_time(@params[:before], "before").to_f if @params[:before].present?
        timestamp[:greater_than] = parse_time(@params[:after], "after").to_f if @params[:after].present?
        timestamp
      end

      # Parse a time filter. Explicit dates are parsed first and anything else is
      # handed to Chronic which understands natural language such as "2 hours
      # ago". This mirrors the parsing used by the web UI.
      #
      # @param [String] string the value provided by the client
      # @param [String] name the name of the parameter, used in error messages
      # @return [Time]
      def parse_time(string, name)
        time = begin
          if string =~ /\A(\d{2,4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})\z/
            Time.new(::Regexp.last_match(1).to_i, ::Regexp.last_match(2).to_i, ::Regexp.last_match(3).to_i, ::Regexp.last_match(4).to_i, ::Regexp.last_match(5).to_i)
          elsif string =~ /\A(\d{2,4})-(\d{2})-(\d{2})\z/
            Time.new(::Regexp.last_match(1).to_i, ::Regexp.last_match(2).to_i, ::Regexp.last_match(3).to_i, 0)
          else
            Chronic.parse(string, context: :past)
          end
        rescue StandardError
          nil
        end

        raise TimeUndetermined, "Couldn't determine a suitable time for the '#{name}' filter from '#{string}'." if time.nil?

        time
      end

      # @return [Boolean]
      def truthy?(value)
        TRUE_VALUES.include?(value.to_s.downcase.strip)
      end

    end
  end
end
