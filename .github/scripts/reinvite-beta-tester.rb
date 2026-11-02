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

def qq_email?(value)
  value.to_s.downcase.end_with?("@qq.com")
end

def create_internal_tester(token, email, first_name, last_name, group_ids)
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

key_path = required_env("ASC_KEY_PATH")
key_id = required_env("ASC_KEY_ID")
issuer_id = required_env("ASC_ISSUER_ID")
token = token_for(key_path, key_id, issuer_id)

apps = expect(*request_json(:get, api_path("/v1/apps", { "filter[bundleId]" => BUNDLE_ID, "limit" => "5" }), token), "List apps").fetch("data")
raise "No App Store Connect app matches #{BUNDLE_ID}" unless apps.length == 1

app = apps.first
app_id = app.fetch("id")
puts "APP id=#{app_id} bundle=#{BUNDLE_ID} name=#{app.dig("attributes", "name").inspect}"

users_code, users_body = request_json(:get, api_path("/v1/users", { "limit" => "200" }), token)
users = users_code == 200 ? users_body.fetch("data") : []
puts "ASC users HTTP #{users_code} count=#{users.length} #{error_text(users_body) unless users_code == 200}"
users.each do |user|
  attributes = user.fetch("attributes")
  puts "USER id=#{user.fetch("id")} username=#{attributes["username"]} first=#{attributes["firstName"]} last=#{attributes["lastName"]} roles=#{attributes["roles"].inspect}"
end
qq_users = users.select { |user| qq_email?(user.dig("attributes", "username")) }
gmail_user = users.find { |user| user.dig("attributes", "username").to_s.casecmp(EMAIL).zero? }
puts "QQ_USERS #{qq_users.map { |user| user.dig("attributes", "username") }.inspect}"
puts "GMAIL_ASC_USER present=#{!gmail_user.nil?} username=#{gmail_user&.dig("attributes", "username")}"

invites_code, invites_body = request_json(:get, api_path("/v1/userInvitations", { "limit" => "200" }), token)
invitations = invites_code == 200 ? invites_body.fetch("data") : []
puts "USER_INVITATIONS HTTP #{invites_code} count=#{invitations.length} #{error_text(invites_body) unless invites_code == 200}"
invitations.each do |invitation|
  attributes = invitation.fetch("attributes")
  puts "USER_INVITATION id=#{invitation.fetch("id")} email=#{attributes["email"]} first=#{attributes["firstName"]} last=#{attributes["lastName"]} roles=#{attributes["roles"].inspect}"
end

groups = expect(*request_json(:get, api_path("/v1/betaGroups", { "filter[app]" => app_id, "limit" => "200" }), token), "List groups").fetch("data")
groups.each do |group|
  attributes = group.fetch("attributes")
  puts "GROUP id=#{group.fetch("id")} name=#{attributes["name"].inspect} internal=#{attributes["isInternalGroup"]}"
end

internal_groups = groups.select { |group| group.dig("attributes", "isInternalGroup") == true }
internal = internal_groups.find { |group| group.dig("attributes", "name") == INTERNAL_GROUP }
raise "Internal group #{INTERNAL_GROUP.inspect} was not found" unless internal

internal_groups.each do |group|
  members_code, members_body = request_json(:get, "/v1/betaGroups/#{group.fetch("id")}/betaTesters?limit=200", token)
  members = members_code == 200 ? members_body.fetch("data") : []
  puts "GROUP_MEMBERS name=#{group.dig("attributes", "name").inspect} HTTP #{members_code} count=#{members.length}"
  members.each do |tester|
    attributes = tester.fetch("attributes")
    puts "MEMBER group=#{group.dig("attributes", "name").inspect} id=#{tester.fetch("id")} email=#{attributes["email"]} state=#{attributes["state"]} inviteType=#{attributes["inviteType"]} first=#{attributes["firstName"]} last=#{attributes["lastName"]}"
  end
  builds_code, builds_body = request_json(:get, "/v1/betaGroups/#{group.fetch("id")}/builds?limit=20", token)
  builds = builds_code == 200 ? builds_body.fetch("data") : []
  builds.each do |build|
    attributes = build.fetch("attributes")
    puts "GROUP_BUILD group=#{group.dig("attributes", "name").inspect} id=#{build.fetch("id")} version=#{attributes["version"]} processing=#{attributes["processingState"]}"
  end
end

# Remove only the empty external group created by the earlier failed run. Do not add testers to it.
groups.select { |group| group.dig("attributes", "isInternalGroup") == false && group.dig("attributes", "name") == "External Testers" }.each do |group|
  members_code, members_body = request_json(:get, "/v1/betaGroups/#{group.fetch("id")}/betaTesters?limit=20", token)
  members = members_code == 200 ? members_body.fetch("data") : nil
  puts "EXTERNAL_GROUP_UNUSED name=#{group.dig("attributes", "name").inspect} id=#{group.fetch("id")} members=#{members&.length || "unknown"}"
  next unless members&.empty?

  delete_code, delete_body = request_json(:delete, "/v1/betaGroups/#{group.fetch("id")}", token)
  puts "DELETED_EMPTY_EXTERNAL_GROUP id=#{group.fetch("id")} HTTP #{delete_code} #{error_text(delete_body) unless delete_code.between?(200, 299)}"
end

all_code, all_body = request_json(:get, api_path("/v1/betaTesters", { "limit" => "200" }), token)
all_testers = all_code == 200 ? all_body.fetch("data") : []
puts "ALL_TESTERS HTTP #{all_code} count=#{all_code == 200 ? all_testers.length : "n/a"} #{error_text(all_body) unless all_code == 200}"
all_testers.each do |tester|
  attributes = tester.fetch("attributes")
  puts "APP_TESTER id=#{tester.fetch("id")} email=#{attributes["email"]} state=#{attributes["state"]} inviteType=#{attributes["inviteType"]} first=#{attributes["firstName"]} last=#{attributes["lastName"]}"
end

email_body = expect(
  *request_json(
    :get,
    api_path("/v1/betaTesters", { "filter[email]" => EMAIL, "include" => "betaGroups", "limit" => "20" }),
    token
  ),
  "List beta testers"
)
testers = email_body.fetch("data")
included_groups = (email_body["included"] || []).select { |row| row["type"] == "betaGroups" }
puts "EMAIL_TESTERS #{EMAIL} count=#{testers.length}"
testers.each do |tester|
  attributes = tester.fetch("attributes")
  group_ids = tester.dig("relationships", "betaGroups", "data")&.map { |row| row["id"] } || []
  names = group_ids.map { |id| included_groups.find { |group| group["id"] == id }&.dig("attributes", "name") || id }
  puts "TESTER id=#{tester.fetch("id")} email=#{attributes["email"]} state=#{attributes["state"]} inviteType=#{attributes["inviteType"]} first=#{attributes["firstName"]} last=#{attributes["lastName"]} groups=#{names.inspect}"
end

qq_testers = all_testers.select { |tester| qq_email?(tester.dig("attributes", "email")) }
puts "QQ_TESTERS #{qq_testers.map { |tester| tester.dig("attributes", "email") }.inspect}"
raise "Refusing to continue: ASC still has a qq.com user and this run will not guess which Apple ID to replace" unless qq_users.empty? && invitations.none? { |invitation| qq_email?(invitation.dig("attributes", "email")) }

unless gmail_user
  puts "ASC_USER_MISSING #{EMAIL} is not an App Store Connect user. The API key cannot create the Account Holder."
  raise "No App Store Connect user uses Apple ID #{EMAIL}"
end

first_name = gmail_user.dig("attributes", "firstName").to_s
first_name = "Kong" if first_name.empty?
last_name = gmail_user.dig("attributes", "lastName").to_s
last_name = "Yi" if last_name.empty?
active = testers.reject { |tester| tester.dig("attributes", "state") == "REVOKED" }
internal_ids = internal_groups.map { |group| group.fetch("id") }

if active.any? { |tester| (tester.dig("relationships", "betaGroups", "data") || []).any? { |row| internal_ids.include?(row["id"]) } }
  keeper = active.find { |tester| (tester.dig("relationships", "betaGroups", "data") || []).any? { |row| internal_ids.include?(row["id"]) } }
  puts "INVITE_ALREADY_ACTIVE id=#{keeper.fetch("id")} email=#{keeper.dig("attributes", "email")} state=#{keeper.dig("attributes", "state")}"
  puts "BETA_REVIEW_NOT_USED internal only"
else
  testers.each do |tester|
    code, body = request_json(:delete, "/v1/betaTesters/#{tester.fetch("id")}", token)
    if code == 404
      puts "TESTER_ALREADY_GONE id=#{tester.fetch("id")}"
    else
      puts "DELETED_TESTER id=#{tester.fetch("id")} HTTP #{code} #{error_text(body) unless code.between?(200, 299)}"
      raise "Could not delete tester #{tester.fetch("id")}" unless code.between?(200, 299)
    end
  end

  created = nil
  code = nil
  body = nil
  5.times do |attempt|
    group_ids = attempt.zero? ? internal_ids : [internal.fetch("id")]
    code, body = create_internal_tester(token, EMAIL, first_name, last_name, group_ids)
    if code.between?(200, 299)
      created = body.fetch("data")
      if group_ids.length == 1
        internal_groups.each do |group|
          next if group.fetch("id") == internal.fetch("id")

          add_code, add_body = add_tester_to_group(token, group.fetch("id"), created.fetch("id"))
          puts "ADDED_TO_GROUP name=#{group.dig("attributes", "name").inspect} HTTP #{add_code} #{error_text(add_body) unless add_code.between?(200, 299)}"
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
  attributes = created.fetch("attributes")
  puts "INVITE_SENT internal tester id=#{created.fetch("id")} email=#{attributes["email"]} state=#{attributes["state"]} groups=#{internal_groups.map { |group| group.dig("attributes", "name") }.inspect}"
  puts "BETA_REVIEW_NOT_USED internal only"
end
