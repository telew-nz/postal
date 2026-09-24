# frozen_string_literal: true

# Helpers which are shared by the request specs for the management API.
module APIHelpers

  # The name of the header which the management API reads its token from.
  API_TOKEN_HEADER = "X-Postal-API-Key"

  # Build the headers which should be sent with a request to the management
  # API. A token record or a plain text key may both be provided.
  #
  # @param [UserAPIToken, String, nil] token
  # @param [Hash] extra additional headers to merge in
  #
  # @return [Hash]
  def api_headers(token = nil, extra = {})
    headers = { "Content-Type" => "application/json", "Accept" => "application/json" }
    key = token.is_a?(UserAPIToken) ? token.plain_key : token
    headers[API_TOKEN_HEADER] = key if key.present?
    headers.merge(extra)
  end

  # Create a user along with an API token which can be used to authenticate
  # requests as that user. Positional arguments are traits which are applied to
  # the token itself (for example :revoked or :expired).
  #
  # @param [Array<Symbol>] token_traits traits to apply to the token
  # @param [User, nil] user an existing user to create the token for
  # @param [Boolean] admin whether a newly created user should be an administrator
  #
  # @return [UserAPIToken]
  def create_api_token(*token_traits, user: nil, admin: false)
    user ||= create(:user, *(admin ? [:admin] : []))
    create(:user_api_token, *token_traits, user: user)
  end

  # Create an organization which the given user is a member of. Ownership on its
  # own is not enough because authorization is based on an organization's
  # members rather than on its owner.
  #
  # @param [User] user
  # @param [Hash] attributes additional attributes for the organization
  #
  # @return [Organization]
  def create_organization(user, **attributes)
    organization = create(:organization, **{ owner: user }.merge(attributes))
    organization.organization_users.create!(user: user)
    organization
  end

  # The parsed body of the response. This returns nil when the response has no
  # body at all so that 204 responses can be asserted against.
  #
  # @return [Hash, Array, nil]
  def parsed_body
    return nil if response.body.blank?

    JSON.parse(response.body)
  end

  # The resource or resources in a successful response.
  #
  # @return [Hash, Array, nil]
  def parsed_data
    parsed_body&.fetch("data", nil)
  end

  # The error object from a failed response.
  #
  # @return [Hash, nil]
  def parsed_error
    parsed_body&.fetch("error", nil)
  end

  # The pagination object from a collection response.
  #
  # @return [Hash, nil]
  def parsed_pagination
    parsed_body&.fetch("pagination", nil)
  end

end
