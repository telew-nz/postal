# frozen_string_literal: true

require "rails_helper"

# The OpenAPI document is maintained by hand so it is important that it cannot
# drift away from the routes which the application actually defines. These
# examples compare the two so that adding an endpoint without documenting it
# fails the suite.
RSpec.describe "Management API OpenAPI Specification", type: :request do
  let(:specification_path) { Rails.root.join("doc/api/openapi.yaml") }

  # The document is written by hand so it may contain YAML timestamps in its
  # examples. These classes must be permitted for it to be parsed safely.
  let(:permitted_yaml_classes) { [Date, Time] }

  let(:http_verbs) { %w[get put post delete patch head options trace] }

  let(:specification) do
    YAML.safe_load(specification_path.read, permitted_classes: permitted_yaml_classes, aliases: true)
  end

  # Every route which Rails knows about beneath /api/v2, expressed using the
  # path templating which OpenAPI uses.
  #
  # @return [Array<Array(String, String)>] an array of [verb, path] pairs
  def defined_routes
    Rails.application.routes.routes.filter_map do |route|
      verbs = route.verb.to_s
      next if verbs.blank?

      path = route.path.spec.to_s.sub(/\(\.:format\)\z/, "")
      next unless path.start_with?("/api/v2")

      openapi_path = path.gsub(/:([^\/]+)/, "{\\1}")
      verbs.split("|").map { |verb| [verb.downcase, openapi_path] }
    end.flatten(1)
  end

  describe "the document itself" do
    it "is a well formed OpenAPI 3 document" do
      expect(specification).to be_a(Hash)
      expect(specification["openapi"]).to match(/\A3\.\d/)
      expect(specification["info"]).to include("title", "version")
      expect(specification["paths"]).to be_a(Hash)
      expect(specification["components"]).to be_a(Hash)
    end

    it "documents the version of the API which the routes are mounted at" do
      expect(specification.dig("info", "version")).to eq("2.0.0")
    end

    it "requires the API key header which the application reads" do
      scheme = specification.dig("components", "securitySchemes", "ApiKeyAuth")
      expect(scheme).to include("type" => "apiKey", "in" => "header", "name" => "X-Postal-API-Key")
      expect(specification["security"]).to eq([{ "ApiKeyAuth" => [] }])
    end

    it "does not override the global security scheme on any operation except the specification itself" do
      overrides = []
      specification["paths"].each do |path, item|
        item.each do |verb, operation|
          next unless http_verbs.include?(verb)
          next if path == "/api/v2/spec"

          overrides << "#{verb.upcase} #{path}" if operation.key?("security")
        end
      end

      expect(overrides).to eq([])
    end

    it "gives every operation a unique identifier" do
      identifiers = []
      specification["paths"].each_value do |item|
        item.each do |verb, operation|
          next unless http_verbs.include?(verb)

          expect(operation["operationId"]).to be_present
          identifiers << operation["operationId"]
        end
      end

      expect(identifiers.uniq).to eq(identifiers)
    end

    it "does not reference a component which does not exist" do
      missing = []
      collect_references(specification, missing)
      expect(missing).to eq([])
    end
  end

  describe "coverage of the application's routes" do
    it "documents every route which the application defines" do
      undocumented = defined_routes.reject do |verb, path|
        specification.dig("paths", path, verb).present?
      end

      details = undocumented.map { |verb, path| "  #{verb.upcase} #{path}" }.join("\n")
      expect(undocumented).to eq([]), "these routes are not documented in doc/api/openapi.yaml:\n#{details}"
    end

    it "does not document any route which the application does not define" do
      stale = []
      specification["paths"].each do |path, item|
        item.each_key do |verb|
          next unless http_verbs.include?(verb)
          next if defined_routes.include?([verb, path])

          stale << "#{verb.upcase} #{path}"
        end
      end

      expect(stale).to eq([]), "these documented routes no longer exist:\n" + stale.map { |route| "  #{route}" }.join("\n")
    end
  end

  describe "GET /api/v2/spec" do
    it "returns the specification as JSON without any authentication" do
      get "/api/v2/spec"

      expect(response.status).to eq(200)
      expect(response.content_type).to include("application/json")
      expect(parsed_body.dig("info", "version")).to eq(specification.dig("info", "version"))
      expect(parsed_body["paths"].keys.sort).to eq(specification["paths"].keys.sort)
    end

    it "returns the specification as YAML when it is requested as YAML" do
      get "/api/v2/spec.yaml"

      expect(response.status).to eq(200)
      expect(response.content_type).to include("application/yaml")
      expect(YAML.safe_load(response.body, permitted_classes: permitted_yaml_classes, aliases: true)).to eq(specification)
    end
  end

  # Walk a parsed document collecting any $ref which cannot be resolved against
  # the document itself.
  #
  # @param [Object] node
  # @param [Array] missing accumulates unresolvable references
  # @return [Array]
  def collect_references(node, missing)
    case node
    when Hash
      node.each do |key, value|
        if key == "$ref" && value.is_a?(String) && value.start_with?("#/")
          missing << value if dig_reference(value).nil?
        else
          collect_references(value, missing)
        end
      end
    when Array
      node.each { |value| collect_references(value, missing) }
    end

    missing
  end

  # Resolve a local JSON pointer against the specification.
  #
  # @param [String] reference
  # @return [Object, nil]
  def dig_reference(reference)
    keys = reference.sub(/\A#\//, "").split("/").map { |key| key.gsub("~1", "/").gsub("~0", "~") }
    specification.dig(*keys)
  end
end
