#!/usr/bin/env ruby
# frozen_string_literal: true

# Create or download the manually managed App Store profile used by the embedded Watch app.
# The profile is matched to the exact distribution certificate stored in CI.

require "base64"
require "digest"
require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

API_ORIGIN = "https://api.appstoreconnect.apple.com"
WATCH_BUNDLE_ID = "com.opencapture.openzcine.watch"
PROFILE_NAME = "OpenZCine_Watch_AppStore"

def required_env(name)
  value = ENV[name]
  abort "Missing #{name}." if value.nil? || value.empty?

  value
end

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def jwt_token(key_id:, issuer_id:, private_key_path:)
  issued_at = Time.now.to_i
  header = { alg: "ES256", kid: key_id, typ: "JWT" }
  payload = {
    iss: issuer_id,
    iat: issued_at,
    exp: issued_at + 1_200,
    aud: "appstoreconnect-v1"
  }
  signing_input = [header, payload].map { |part| base64url(JSON.generate(part)) }.join(".")
  key = OpenSSL::PKey.read(File.binread(private_key_path))
  signature_der = key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(signing_input))
  signature_values = OpenSSL::ASN1.decode(signature_der).value
  signature = signature_values.map do |integer|
    [integer.value.to_i.to_s(16).rjust(64, "0")].pack("H*")
  end.join
  "#{signing_input}.#{base64url(signature)}"
end

def api_request(token:, method:, path:, body: nil)
  uri = path.start_with?("http") ? URI(path) : URI("#{API_ORIGIN}#{path}")
  request_class = {
    get: Net::HTTP::Get,
    post: Net::HTTP::Post,
    delete: Net::HTTP::Delete
  }.fetch(method)
  request = request_class.new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json" if body
  request.body = JSON.generate(body) if body

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 30
  http.read_timeout = 60
  response = http.request(request)
  unless response.code.to_i.between?(200, 299)
    details = begin
      JSON.parse(response.body).fetch("errors", []).map { |error| error["detail"] }.compact.join("; ")
    rescue JSON::ParserError
      response.body
    end
    abort "App Store Connect API #{method.to_s.upcase} #{uri.request_uri} failed (#{response.code}): #{details}"
  end

  response.body.nil? || response.body.empty? ? {} : JSON.parse(response.body)
end

def paginated_resources(token:, path:)
  resources = []
  next_path = path
  while next_path
    response = api_request(token: token, method: :get, path: next_path)
    resources.concat(response.fetch("data"))
    next_path = response.dig("links", "next")
  end
  resources
end

key_id = required_env("APP_STORE_CONNECT_API_KEY_ID")
issuer_id = required_env("APP_STORE_CONNECT_API_ISSUER_ID")
private_key_path = required_env("APP_STORE_CONNECT_API_KEY_PATH")
local_fingerprint = required_env("IOS_DISTRIBUTION_CERTIFICATE_SHA256").downcase
output_path = required_env("IOS_WATCH_PROFILE_OUTPUT_PATH")
abort "IOS_DISTRIBUTION_CERTIFICATE_SHA256 must be a SHA-256 fingerprint." unless local_fingerprint.match?(/\A[0-9a-f]{64}\z/)

token = jwt_token(key_id: key_id, issuer_id: issuer_id, private_key_path: private_key_path)

bundle_query = URI.encode_www_form("filter[identifier]" => WATCH_BUNDLE_ID, "limit" => "2")
bundle_ids = api_request(token: token, method: :get, path: "/v1/bundleIds?#{bundle_query}").fetch("data")
bundle_id = bundle_ids.find { |resource| resource.dig("attributes", "identifier") == WATCH_BUNDLE_ID }
abort "Bundle ID #{WATCH_BUNDLE_ID} is not registered with Apple Developer." unless bundle_id

certificates = paginated_resources(token: token, path: "/v1/certificates?limit=200")
certificate = certificates.find do |resource|
  content = resource.dig("attributes", "certificateContent")
  content && Digest::SHA256.hexdigest(Base64.decode64(content)) == local_fingerprint
end
abort "The CI Apple Distribution certificate was not found in Apple Developer." unless certificate

profiles = paginated_resources(token: token, path: "/v1/profiles?limit=200")
matching_profiles = profiles.select { |resource| resource.dig("attributes", "name") == PROFILE_NAME }
profile = matching_profiles.find do |resource|
  next false unless resource.dig("attributes", "profileState") == "ACTIVE"

  profile_id = resource.fetch("id")
  profile_bundle_id = api_request(
    token: token, method: :get, path: "/v1/profiles/#{profile_id}/bundleId"
  ).dig("data", "id")
  profile_certificate_ids = api_request(
    token: token, method: :get, path: "/v1/profiles/#{profile_id}/certificates"
  ).fetch("data").map { |item| item.fetch("id") }
  profile_bundle_id == bundle_id.fetch("id") && profile_certificate_ids.include?(certificate.fetch("id"))
end

unless profile
  matching_profiles.each do |resource|
    api_request(token: token, method: :delete, path: "/v1/profiles/#{resource.fetch("id")}")
  end
  payload = {
    data: {
      type: "profiles",
      attributes: {
        name: PROFILE_NAME,
        profileType: "IOS_APP_STORE"
      },
      relationships: {
        bundleId: { data: { type: "bundleIds", id: bundle_id.fetch("id") } },
        certificates: {
          data: [{ type: "certificates", id: certificate.fetch("id") }]
        }
      }
    }
  }
  profile = api_request(token: token, method: :post, path: "/v1/profiles", body: payload).fetch("data")
  puts "Created Watch App Store provisioning profile: #{PROFILE_NAME}"
else
  puts "Using Watch App Store provisioning profile: #{PROFILE_NAME}"
end

profile_content = profile.dig("attributes", "profileContent")
abort "Apple returned a profile without profileContent." if profile_content.nil? || profile_content.empty?

File.binwrite(output_path, Base64.decode64(profile_content))
