# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

STDOUT.sync = true
API_ROOT = "https://api.appstoreconnect.apple.com"
EMAIL = ENV.fetch("BETA_TESTER_EMAIL", "sharkchili.su@gmail.com")
BUNDLE_ID = ENV.fetch("APP_BUNDLE_ID", "com.harrisliangsu.whenreset")
INTERNAL_GROUP = ENV.fetch("TESTFLIGHT_GROUP_NAME", "Internal Testers")
EXTERNAL_GROUP = ENV.fetch("EXTERNAL_GROUP_NAME", "External Testers")
MARKETING_VERSION = ENV.fetch("MARKETING_VERSION", "1.8")
BUILD_NUMBER = ENV.fetch("BUILD_NUMBER", "2")

def required_env(name)
  value = ENV[name]
  raise "Required environment variable #{name} is missing" if value.nil? || value.empty?

  value
end

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def jose_signature(key, signing_input)
  digest = OpenSSL::Digest::SHA256.digest(signing_input)
  sequence = OpenSSL::ASN1.decode(key.dsa_sign_asn1(digest))
  integers = sequence.value.map { |part| part.value.to_i.to_s(16).rjust(64, "0") }
  [integers.join].pack("H*")
end

def token_for(key_path, key_id, issuer_id)
  now = Time.now.to_i
  header = base64url(JSON.generate(alg: "ES256", kid: key_id, typ: "JWT"))
  payload = base64url(JSON.generate(iss: issuer_id, iat: now - 30, exp: now + 600, aud: "appstoreconnect-v1"))
  signing_input = "#{header}.#{payload}"
  key = OpenSSL::PKey::EC.new(File.read(key_path))
  "#{signing_input}.#{base64url(jose_signature(key, signing_input))}"
end

def request_json(method, path, token, body = nil)
  uri = URI("#{API_ROOT}#{path}")
  request_class = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete, patch: Net::HTTP::Patch }.fetch(method)
  request = request_class.new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json" if body
  request.body = JSON.generate(body) if body
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) do |http|
    http.request(request)
  end
  parsed = response.body.nil? || response.body.empty? ? {} : JSON.parse(response.body)
  [response.code.to_i, parsed]
rescue JSON::ParserError
  [response.code.to_i, { "raw" => response.body.to_s[0, 500] }]
end

def api_path(path, parameters = nil)
  return path if parameters.nil? || parameters.empty?

  "#{path}?#{URI.encode_www_form(parameters)}"
end

def expect(code, parsed, what)
  return parsed if code.between?(200, 299)

  raise "#{what} failed with HTTP #{code}: #{error_text(parsed)}"
end

def error_text(parsed)
  parsed.dig("errors")&.map { |error| [error["title"], error["detail"]].compact.join(": ") }&.join("; ") || parsed.to_s
end

def create_tester(token, email, first_name, last_name, group_ids)
  request_json(
    :post,
    "/v1/betaTesters",
    token,
    {
      data: {
        type: "betaTesters",
        attributes: { email: email, firstName: first_name, lastName: last_name },
        relationships: {
          betaGroups: { data: group_ids.map { |id| { type: "betaGroups", id: id } } }
        }
      }
    }
  )
end

def add_tester_to_group(token, group_id, tester_id)
  request_json(
    :post,
    "/v1/betaGroups/#{group_id}/relationships/betaTesters",
    token,
    { data: [{ type: "betaTesters", id: tester_id }] }
  )
end

def delete_testers(token, testers)
  testers.each do |tester|
    code, body = request_json(:delete, "/v1/betaTesters/#{tester.fetch("id")}", token)
    puts "Deleted tester #{tester.fetch("id")} email=#{tester.dig("attributes", "email")} HTTP #{code} #{error_text(body) unless code.between?(200, 299)}"
    raise "Could not delete tester #{tester.fetch("id")}" unless code.between?(200, 299)
  end
end

def find_build(token, app_id)
  versions = expect(
    *request_json(
      :get,
      api_path("/v1/preReleaseVersions", { "filter[app]" => app_id, "filter[version]" => MARKETING_VERSION, "filter[platform]" => "IOS", "limit" => "20" }),
      token
    ),
    "List prerelease versions"
  ).fetch("data")
  builds = versions.flat_map do |version|
    expect(
      *request_json(:get, api_path("/v1/builds", { "filter[preReleaseVersion]" => version.fetch("id"), "filter[version]" => BUILD_NUMBER, "limit" => "20" }), token),
      "List builds"
    ).fetch("data")
  end
  builds.find { |build| build.dig("attributes", "version") == BUILD_NUMBER }
end

def ensure_export_compliance(token, build)
  return build unless build.dig("attributes", "usesNonExemptEncryption").nil?

  code, body = request_json(
    :patch,
    "/v1/builds/#{build.fetch("id")}",
    token,
    { data: { type: "builds", id: build.fetch("id"), attributes: { usesNonExemptEncryption: false } } }
  )
  if code.between?(200, 299)
    puts "Declared usesNonExemptEncryption=false, matching Info.plist."
    body.fetch("data")
  else
    puts "EXPORT_COMPLIANCE_UNCHANGED HTTP #{code}: #{error_text(body)}"
    build
  end
end

def assign_build(token, group_id, build)
  code, body = request_json(
    :post,
    "/v1/betaGroups/#{group_id}/relationships/builds",
    token,
    { data: [{ type: "builds", id: build.fetch("id") }] }
  )
  if code == 409
    puts "Build already assigned to the group"
    true
  elsif code.between?(200, 299)
    puts "Assigned build #{MARKETING_VERSION} (#{BUILD_NUMBER}) to the group"
    true
  else
    puts "BUILD_ASSIGN_FAILED HTTP #{code}: #{error_text(body)}"
    false
  end
end

def submit_beta_review(token, app_id, build)
  review_code, review_body = request_json(:get, "/v1/builds/#{build.fetch("id")}/betaAppReviewSubmission", token)
  existing = review_code == 200 ? review_body["data"] : nil
  state = existing&.dig("attributes", "betaReviewState")
  puts "Existing beta review HTTP #{review_code} state=#{state.inspect}"
  if existing && state != "REJECTED"
    puts "BETA_REVIEW_ALREADY state=#{state}"
    return
  end

  detail_code, detail_body = request_json(:get, "/v1/apps/#{app_id}/betaAppReviewDetail", token)
  detail = detail_code == 200 ? detail_body["data"] : nil
  if detail
    attributes = detail.fetch("attributes")
    puts "Beta review contact email=#{attributes["contactEmail"].inspect} phone_present=#{!attributes["contactPhone"].to_s.empty?} notes_present=#{!attributes["notes"].to_s.empty?}"
    needs = attributes["contactEmail"].to_s.empty? || attributes["contactFirstName"].to_s.empty? || attributes["contactLastName"].to_s.empty?
    if needs
      patch_code, patch_body = request_json(
        :patch,
        "/v1/betaAppReviewDetails/#{detail.fetch("id")}",
        token,
        {
          data: {
            type: "betaAppReviewDetails",
            id: detail.fetch("id"),
            attributes: {
              contactEmail: attributes["contactEmail"].to_s.empty? ? EMAIL : attributes["contactEmail"],
              contactFirstName: attributes["contactFirstName"].to_s.empty? ? "Harris" : attributes["contactFirstName"],
              contactLastName: attributes["contactLastName"].to_s.empty? ? "Su" : attributes["contactLastName"],
              demoAccountRequired: false,
              notes: attributes["notes"].to_s.empty? ? "Blinky shows provider usage limits. No demo account is required; the first screen is an empty usage list until an account is connected." : attributes["notes"]
            }
          }
        }
      )
      expect(patch_code, patch_body, "Update beta review contact")
      puts "Filled missing beta review contact fields. No phone number was added."
    end
  else
    puts "Beta review detail HTTP #{detail_code}: #{error_text(detail_body)}"
  end

  submit_code, submit_body = request_json(
    :post,
    "/v1/betaAppReviewSubmissions",
    token,
    { data: { type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id: build.fetch("id") } } } } }
  )
  if submit_code.between?(200, 299)
    submitted_state = submit_body.dig("data", "attributes", "betaReviewState")
    puts "BETA_REVIEW_SUBMITTED id=#{submit_body.dig("data", "id")} state=#{submitted_state}"
  else
    puts "BETA_REVIEW_NOT_SUBMITTED HTTP #{submit_code}: #{error_text(submit_body)}"
  end
end

def ensure_external_group(token, app_id, groups)
  external = groups.find { |group| group.dig("attributes", "name") == EXTERNAL_GROUP && group.dig("attributes", "isInternalGroup") == false }
  return external if external

  code, body = request_json(
    :post,
    "/v1/betaGroups",
    token,
    {
      data: {
        type: "betaGroups",
        attributes: { name: EXTERNAL_GROUP, isInternalGroup: false, publicLinkEnabled: false, feedbackEnabled: true },
        relationships: { app: { data: { type: "apps", id: app_id } } }
      }
    }
  )
  created = expect(code, body, "Create external group").fetch("data")
  puts "Created external group #{created.fetch("id")}"
  created
end

def invite_external(token, app_id, groups, testers, first_name, last_name)
  external = ensure_external_group(token, app_id, groups)
  already = testers.select do |tester|
    group_ids = tester.dig("relationships", "betaGroups", "data")&.map { |row| row["id"] } || []
    group_ids.include?(external.fetch("id"))
  end
  if already.empty?
    delete_testers(token, testers)
    code, body = create_tester(token, EMAIL, first_name, last_name, [external.fetch("id")])
    if code.between?(200, 299)
      puts "INVITE_SENT external tester id=#{body.dig("data", "id")} email=#{EMAIL}"
    else
      puts "EXTERNAL_INVITE_FAILED HTTP #{code}: #{error_text(body)}"
      raise "External invite failed"
    end
  else
    puts "INVITE_ALREADY_PRESENT external tester id=#{already.first.fetch("id")} email=#{EMAIL} (no new email sent)"
  end

  build = find_build(token, app_id)
  raise "Build #{MARKETING_VERSION} (#{BUILD_NUMBER}) was not found" unless build

  puts "Build id=#{build.fetch("id")} processing=#{build.dig("attributes", "processingState")} encryption=#{build.dig("attributes", "usesNonExemptEncryption").inspect}"
  build = ensure_export_compliance(token, build)
  detail_code, detail_body = request_json(:get, "/v1/builds/#{build.fetch("id")}/buildBetaDetail", token)
  if detail_code == 200
    attributes = detail_body.dig("data", "attributes") || {}
    puts "BUILD_BETA internal=#{attributes["internalBuildState"]} external=#{attributes["externalBuildState"]}"
  else
    puts "BUILD_BETA HTTP #{detail_code}: #{error_text(detail_body)}"
  end
  assigned = assign_build(token, external.fetch("id"), build)
  submit_beta_review(token, app_id, build)
  assign_build(token, external.fetch("id"), build) unless assigned
end

key_path = required_env("ASC_KEY_PATH")
key_id = required_env("ASC_KEY_ID")
issuer_id = required_env("ASC_ISSUER_ID")
token = token_for(key_path, key_id, issuer_id)

apps = expect(*request_json(:get, api_path("/v1/apps", { "filter[bundleId]" => BUNDLE_ID, "limit" => "1" }), token), "List apps").fetch("data")
raise "No App Store Connect app matches #{BUNDLE_ID}" unless apps.length == 1

app_id = apps.first.fetch("id")
puts "App #{BUNDLE_ID} id=#{app_id}"

users_code, users_body = request_json(:get, api_path("/v1/users", { "limit" => "200" }), token)
users = users_code == 200 ? users_body.fetch("data") : []
puts "ASC users HTTP #{users_code} count=#{users.length} #{error_text(users_body) unless users_code == 200}"
users.each do |user|
  attributes = user.fetch("attributes")
  puts "USER id=#{user.fetch("id")} username=#{attributes["username"]} first=#{attributes["firstName"]} last=#{attributes["lastName"]} roles=#{attributes["roles"].inspect}"
end

filtered_code, filtered_body = request_json(:get, api_path("/v1/users", { "filter[username]" => EMAIL, "limit" => "10" }), token)
puts "ASC username filter #{EMAIL} HTTP #{filtered_code} count=#{filtered_code == 200 ? filtered_body.fetch("data").length : "n/a"}"

groups = expect(*request_json(:get, api_path("/v1/betaGroups", { "filter[app]" => app_id, "limit" => "200" }), token), "List groups").fetch("data")
groups.each do |group|
  attributes = group.fetch("attributes")
  puts "GROUP id=#{group.fetch("id")} name=#{attributes["name"].inspect} internal=#{attributes["isInternalGroup"]}"
end
internal = groups.find { |group| group.dig("attributes", "name") == INTERNAL_GROUP && group.dig("attributes", "isInternalGroup") == true }
raise "Internal group #{INTERNAL_GROUP.inspect} was not found" unless internal

internal_members_code, internal_members_body = request_json(:get, "/v1/betaGroups/#{internal.fetch("id")}/betaTesters?limit=200", token)
internal_members = internal_members_code == 200 ? internal_members_body.fetch("data") : []
puts "Internal Testers membership HTTP #{internal_members_code} count=#{internal_members.length}"
internal_members.each do |tester|
  attributes = tester.fetch("attributes")
  puts "INTERNAL_MEMBER id=#{tester.fetch("id")} email=#{attributes["email"]} inviteType=#{attributes["inviteType"]} state=#{attributes["state"]} first=#{attributes["firstName"]} last=#{attributes["lastName"]}"
end

testers_body = expect(
  *request_json(
    :get,
    api_path("/v1/betaTesters", { "filter[email]" => EMAIL, "filter[apps]" => app_id, "include" => "betaGroups", "limit" => "20" }),
    token
  ),
  "List beta testers"
)
testers = testers_body.fetch("data")
included_groups = (testers_body["included"] || []).select { |row| row["type"] == "betaGroups" }
puts "Beta testers for #{EMAIL}: #{testers.length}"
testers.each do |tester|
  attributes = tester.fetch("attributes")
  group_ids = tester.dig("relationships", "betaGroups", "data")&.map { |row| row["id"] } || []
  names = group_ids.map { |id| included_groups.find { |group| group["id"] == id }&.dig("attributes", "name") || id }
  puts "TESTER id=#{tester.fetch("id")} email=#{attributes["email"]} inviteType=#{attributes["inviteType"]} state=#{attributes["state"]} first=#{attributes["firstName"]} last=#{attributes["lastName"]} groups=#{names.inspect}"
end

gmail_user = users.find { |user| user.dig("attributes", "username").to_s.casecmp(EMAIL).zero? }
gmail_user ||= filtered_body.fetch("data").find { |user| user.dig("attributes", "username").to_s.casecmp(EMAIL).zero? } if filtered_code == 200
qq_users = users.select { |user| user.dig("attributes", "username").to_s.downcase.end_with?("@qq.com") }
puts "Gmail ASC user present=#{!gmail_user.nil?} qq ASC users=#{qq_users.map { |user| user.dig("attributes", "username") }.inspect}"
first_name = gmail_user&.dig("attributes", "firstName").to_s
first_name = "Harris" if first_name.empty?
last_name = gmail_user&.dig("attributes", "lastName").to_s
last_name = "Su" if last_name.empty?

# An internal TestFlight invite is accepted with the App Store Connect user's Apple ID.
# That username is the gmail address, so a fresh internal invite is the one the phone can accept.
# There is no qq.com App Store Connect user to bind instead.
if gmail_user
  puts "ACTION reinvite-internal because an App Store Connect user has Apple ID #{EMAIL}"
  delete_testers(token, testers)
  internal_groups = groups.select { |group| group.dig("attributes", "isInternalGroup") == true }
  code, body = nil
  created = nil
  5.times do |attempt|
    group_ids = attempt.zero? ? internal_groups.map { |group| group.fetch("id") } : [internal.fetch("id")]
    code, body = create_tester(token, EMAIL, first_name, last_name, group_ids)
    if code.between?(200, 299)
      created = body.fetch("data")
      if group_ids.length == 1
        internal_groups.each do |group|
          next if group.fetch("id") == internal.fetch("id")

          add_code, add_body = add_tester_to_group(token, group.fetch("id"), created.fetch("id"))
          puts "Added tester to #{group.dig("attributes", "name")} HTTP #{add_code} #{error_text(add_body) unless add_code.between?(200, 299)}"
        end
      end
      break
    end
    puts "INTERNAL_INVITE_ATTEMPT #{attempt + 1} HTTP #{code}: #{error_text(body)}"
    sleep 3
  end
  unless created
    puts "INTERNAL_INVITE_FAILED HTTP #{code}: #{error_text(body)}"
    raise "Internal reinvite failed"
  end
  puts "INVITE_SENT internal tester id=#{created.fetch("id")} email=#{EMAIL} groups=#{internal_groups.map { |group| group.dig("attributes", "name") }.inspect}"
  puts "BETA_REVIEW_NOT_REQUIRED internal group"
  external = groups.find { |group| group.dig("attributes", "name") == EXTERNAL_GROUP && group.dig("attributes", "isInternalGroup") == false }
  if external
    members_code, members_body = request_json(:get, "/v1/betaGroups/#{external.fetch("id")}/betaTesters?limit=20", token)
    members = members_code == 200 ? members_body.fetch("data") : nil
    if members&.empty?
      delete_code, delete_body = request_json(:delete, "/v1/betaGroups/#{external.fetch("id")}", token)
      puts "Deleted empty external group #{external.fetch("id")} HTTP #{delete_code} #{error_text(delete_body) unless delete_code.between?(200, 299)}"
    else
      puts "Left external group #{external.fetch("id")} in place members=#{members&.length || "unknown"}"
    end
  end
else
  reason = if users_code != 200
    "the user list returned HTTP #{users_code}, so #{EMAIL} is not a confirmed App Store Connect Apple ID"
  elsif qq_users.any?
    "the team Apple ID is #{qq_users.map { |user| user.dig("attributes", "username") }.join(", ")}"
  else
    "no App Store Connect user has Apple ID #{EMAIL}"
  end
  puts "ACTION external-group because #{reason}. Internal testing cannot be accepted by Apple ID #{EMAIL}."
  invite_external(token, app_id, groups, testers, first_name, last_name)
end
