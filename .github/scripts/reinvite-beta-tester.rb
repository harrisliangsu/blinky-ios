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

OLD_TESTER_ID = "7a36386a-35b4-4a58-8feb-6136ba3bd2b8"
QQ_HITS = []

def qq_email?(value)
  value.to_s.downcase.end_with?("@qq.com")
end

def remember_qq(value, path)
  return unless value.is_a?(String) && value.downcase.include?("qq")

  hit = "#{path}=#{value}"
  QQ_HITS << hit
  puts "QQ_HIT #{hit}"
end

def walk_qq(value, path)
  case value
  when Hash
    value.each { |key, child| walk_qq(child, "#{path}.#{key}") }
  when Array
    value.each_with_index { |child, index| walk_qq(child, "#{path}[#{index}]") }
  else
    remember_qq(value.to_s, path) if value.is_a?(String)
  end
end

def dump(label, code, body)
  puts "---- #{label} HTTP #{code} ----"
  puts JSON.pretty_generate(body)
  walk_qq(body, label)
end

def urls_in(value, found = [])
  case value
  when Hash
    value.each_value { |child| urls_in(child, found) }
  when Array
    value.each { |child| urls_in(child, found) }
  when String
    found << value if value.include?("http://") || value.include?("https://")
  end
  found
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
dump("users", users_code, users_body)
users = users_code == 200 ? users_body.fetch("data") : []
users.each do |user|
  detail_code, detail_body = request_json(:get, "/v1/users/#{user.fetch("id")}", token)
  dump("user #{user.fetch("id")}", detail_code, detail_body)
end
gmail_user = users.find { |user| user.dig("attributes", "username").to_s.casecmp(EMAIL).zero? }
qq_users = users.select { |user| qq_email?(user.dig("attributes", "username")) }
puts "GMAIL_ASC_USER present=#{!gmail_user.nil?} username=#{gmail_user&.dig("attributes", "username")}"
puts "QQ_USERS #{qq_users.map { |user| user.dig("attributes", "username") }.inspect}"

invites_code, invites_body = request_json(:get, api_path("/v1/userInvitations", { "limit" => "200" }), token)
dump("userInvitations", invites_code, invites_body)
invitations = invites_code == 200 ? invites_body.fetch("data") : []

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

all_code, all_body = request_json(:get, api_path("/v1/betaTesters", { "limit" => "200" }), token)
dump("betaTesters", all_code, all_body)
qq_filter_code, qq_filter_body = request_json(:get, api_path("/v1/betaTesters", { "filter[email]" => "*@qq.com", "limit" => "20" }), token)
dump("betaTesters filter *@qq.com", qq_filter_code, qq_filter_body)

old_code, old_body = request_json(
  :get,
  api_path("/v1/betaTesters/#{OLD_TESTER_ID}", { "include" => "apps,betaGroups,builds" }),
  token
)
dump("betaTester #{OLD_TESTER_ID} include=apps,betaGroups,builds", old_code, old_body)
if old_code != 200
  %w[apps betaGroups builds].each do |name|
    rel_code, rel_body = request_json(:get, "/v1/betaTesters/#{OLD_TESTER_ID}/#{name}?limit=50", token)
    dump("betaTester #{OLD_TESTER_ID} /#{name}", rel_code, rel_body)
  end
end
old_urls = urls_in(old_body)
puts "OLD_TESTER_URLS #{old_urls.inspect}"

email_code, email_body = request_json(
  :get,
  api_path("/v1/betaTesters", { "filter[email]" => EMAIL, "include" => "apps,betaGroups,builds", "limit" => "20" }),
  token
)
dump("betaTesters filter #{EMAIL}", email_code, email_body)
testers = email_code == 200 ? email_body.fetch("data") : []

raise "No App Store Connect user uses Apple ID #{EMAIL}" unless gmail_user

first_name = gmail_user.dig("attributes", "firstName").to_s
first_name = "Kong" if first_name.empty?
last_name = gmail_user.dig("attributes", "lastName").to_s
last_name = "Yi" if last_name.empty?

delete_code, delete_body = request_json(:delete, "/v1/betaTesters/#{OLD_TESTER_ID}", token)
puts "DELETE_BETA_TESTER id=#{OLD_TESTER_ID} HTTP #{delete_code} #{error_text(delete_body) unless delete_code.between?(200, 299) || delete_code == 404}"
raise "DELETE betaTester failed HTTP #{delete_code}" unless delete_code.between?(200, 299) || delete_code == 404

deadline = Time.now + 300
attempt = 0
list_empty = false
while Time.now < deadline
  sleep 15
  attempt += 1
  list_code, list_body = request_json(:get, api_path("/v1/betaTesters", { "filter[email]" => EMAIL, "limit" => "20" }), token)
  remaining = list_code == 200 ? list_body.fetch("data").map { |tester| tester.fetch("id") } : nil
  puts "POLL #{attempt} HTTP #{list_code} ids=#{remaining.inspect} elapsed=#{attempt * 15}s"
  list_empty = list_code == 200 && remaining.empty?
end
puts "EMAIL_FILTER_EMPTY_AFTER_WAIT #{list_empty}"
raise "sharkchili.su@gmail.com still has a beta tester after 5 minutes" unless list_empty

created = nil
code = nil
body = nil
group_sets = [internal_groups.map { |group| group.fetch("id") }, [internal.fetch("id")]]
group_sets.each_with_index do |group_ids, attempt_index|
  code, body = create_internal_tester(token, EMAIL, first_name, last_name, group_ids)
  puts "CREATE_HTTP attempt=#{attempt_index + 1} groups=#{group_ids.inspect} HTTP #{code} id=#{body.dig("data", "id")} #{error_text(body) unless code.between?(200, 299)}"
  if code.between?(200, 299)
    created = body.fetch("data")
    break
  end
end
raise "Internal reinvite failed HTTP #{code}: #{error_text(body)}" unless created

new_id = created.fetch("id")
internal_groups.each do |group|
  next if group.fetch("id") == internal.fetch("id")

  add_code, add_body = add_tester_to_group(token, group.fetch("id"), new_id)
  puts "ADDED_TO_GROUP name=#{group.dig("attributes", "name").inspect} HTTP #{add_code} #{error_text(add_body) unless add_code.between?(200, 299)}"
end

new_code, new_body = request_json(
  :get,
  api_path("/v1/betaTesters/#{new_id}", { "include" => "apps,betaGroups,builds" }),
  token
)
dump("betaTester #{new_id} after create", new_code, new_body)
new_urls = urls_in(new_body)
puts "NEW_TESTER_URLS #{new_urls.inspect}"
puts "OLD_TESTER_ID #{OLD_TESTER_ID}"
puts "NEW_TESTER_ID #{new_id}"
puts "TESTER_ID_CHANGED #{new_id != OLD_TESTER_ID}"
puts "INVITE_SENT email=#{created.dig("attributes", "email")} state=#{created.dig("attributes", "state")} id=#{new_id}"
puts "QQ_HITS #{QQ_HITS.empty? ? "none" : QQ_HITS.uniq.inspect}"
puts "BETA_REVIEW_NOT_USED internal only"
