# frozen_string_literal: true

module API
  module V2
    # The base class for all management API serializers. Serializers are
    # responsible for converting a record into a hash which is suitable for
    # rendering as JSON.
    #
    # Every serializer declares its attributes explicitly rather than dumping
    # the record's attributes wholesale. This ensures that sensitive data (such
    # as DKIM private keys) can never be leaked by a new column being added to
    # a table.
    class BaseSerializer

      BOOLEAN_TYPE = ActiveModel::Type::Boolean.new

      # Render a collection of records using this serializer.
      #
      # @param [Array] records
      # @param [Hash] options
      # @return [Array<Hash>]
      def self.collection(records, options = {})
        records.map { |record| new(record, options).as_json }
      end

      def initialize(record, options = {})
        @record = record
        @options = options
      end

      attr_reader :record

      attr_reader :options

      # Return the JSON representation of the record.
      #
      # @return [Hash]
      def as_json(*)
        raise NotImplementedError, "#{self.class} must implement #as_json"
      end

      private

      # Read an attribute from the record. Records from the message database are
      # either objects which use method_missing over a string keyed hash or raw
      # hashes themselves so both are handled here.
      #
      # @param [String, Symbol] name
      # @return [Object]
      def attribute(name)
        return record.public_send(name) unless record.is_a?(Hash)

        record.key?(name.to_s) ? record[name.to_s] : record[name.to_sym]
      end

      # Render a time as an ISO 8601 string in UTC. Values stored in the
      # message database are decimal UNIX timestamps so numerics are converted
      # before being rendered.
      #
      # @param [Time, ActiveSupport::TimeWithZone, Numeric, nil] value
      # @return [String, nil]
      def iso8601(value)
        return nil if value.nil?

        value = Time.zone.at(value) if value.is_a?(Numeric)
        value.utc.iso8601
      end

      # Render a decimal as a float so that it is not quoted in the response.
      #
      # @param [BigDecimal, nil] value
      # @return [Float, nil]
      def decimal(value)
        value&.to_f
      end

      # Render a value as a proper JSON boolean. Columns in the message
      # database are stored as tinyints so they arrive here as 0 or 1.
      #
      # @param [Object] value
      # @return [Boolean]
      def boolean(value)
        BOOLEAN_TYPE.cast(value) == true
      end

      # Split a newline delimited text column into an array of values.
      #
      # @param [String, nil] value
      # @return [Array<String>]
      def lines(value)
        value.to_s.split(/[\r\n]+/).map(&:strip).reject(&:empty?)
      end

      # Ensure a string is valid UTF-8 before it is rendered as JSON. Values
      # read from the message database (SMTP output in particular) may contain
      # binary data which would otherwise cause JSON generation to fail.
      #
      # @param [String, nil] value
      # @return [String, nil]
      def text(value)
        return nil if value.nil?

        value.to_s.dup.force_encoding("UTF-8").scrub
      end

    end
  end
end
