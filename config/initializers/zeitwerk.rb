# frozen_string_literal: true

Rails.autoloaders.each do |autoloader|
  # Ignore the message DB migrations directory as it doesn't follow
  # Zeitwerk's conventions and is always loaded and executed in order.
  autoloader.ignore(Rails.root.join("lib/postal/message_db/migrations"))
end

# The concerns directory for the management API contains modules which belong
# to the API::V2 namespace itself rather than to an API::V2::Concerns namespace.
# This mirrors the way app/controllers/concerns behaves for the web UI.
Rails.autoloaders.main.collapse(Rails.root.join("app/controllers/api/v2/concerns"))
