# frozen_string_literal: true

module API
  module V2
    # IP pools are read only in this API. Creating and changing them is part of
    # the global administration surface which is out of scope but they are
    # listed here because servers and IP pool rules both reference a pool by ID
    # and clients need a way to discover the values which are valid.
    class IPPoolsController < BaseController

      def index
        pools, pagination = paginate(IPPool.order(:name, :id))
        render_collection(IPPoolSerializer.collection(pools), pagination)
      end

    end
  end
end
