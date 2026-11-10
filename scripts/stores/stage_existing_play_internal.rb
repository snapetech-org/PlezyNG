#!/usr/bin/env ruby
# First-publication bootstrap only: attach immutable uploaded166 to an internal
# draft. No AAB upload, review submission, completed release, or production edit.
require 'googleauth'
require 'json'
require 'net/http'
require 'stringio'
require 'uri'

package = 'org.snapetech.pleazyng'
version = 166
output = ENV.fetch('PLAY_STAGE_RECEIPT')
manifest = File.readlines(ENV.fetch('PLAY_CHECKSUM_MANIFEST')).map(&:split).select { |row| row[1] == 'pleazyng-android-play.aab' }
abort 'Expected exactly one attested original AAB checksum' unless manifest.length == 1 && manifest[0][0].match?(/\A[0-9a-f]{64}\z/)
expected = manifest[0][0]
credentials = Google::Auth::ServiceAccountCredentials.make_creds(
  json_key_io: StringIO.new(ENV.fetch('SUPPLY_JSON_KEY_DATA')),
  scope: 'https://www.googleapis.com/auth/androidpublisher'
)
token = credentials.fetch_access_token!.fetch('access_token')
base = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/#{package}"
api = lambda do |method, path, body = nil|
  uri = URI(base + path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request['Authorization'] = "Bearer #{token}"
  if body
    request['Content-Type'] = 'application/json'
    request.body = JSON.generate(body)
  end
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 120) { |http| http.request(request) }
  unless response.is_a?(Net::HTTPSuccess)
    message = (JSON.parse(response.body).dig('error', 'message') rescue 'No structured error')
    raise "Play #{method} failed HTTP #{response.code}: #{message}"
  end
  response.body.to_s.empty? ? {} : JSON.parse(response.body)
end
edit = nil
committed = false
begin
  edit = api.call('post', '/edits', {}).fetch('id')
  bundles = api.call('get', "/edits/#{edit}/bundles").fetch('bundles', [])
  bundle = bundles.find { |item| item['versionCode'] == version }
  abort "Existing bundle166 not in edit; available versions: #{bundles.map { |item| item['versionCode'] }}" unless bundle
  abort 'Original release AAB checksum does not match Play upload' unless bundle.fetch('sha256').downcase == expected
  track = api.call('get', "/edits/#{edit}/tracks/internal")
  releases = track.fetch('releases', [])
  allowed = releases.all? { |release| release['status'] == 'draft' && (release.fetch('versionCodes', []).map(&:to_i) - [version]).empty? }
  abort 'Internal track contains unrelated or active release; refusing replacement' unless allowed
  staged = {
    'track' => 'internal',
    'releases' => [{ 'name' => '3.0.7 - native qualification', 'status' => 'draft', 'versionCodes' => [version.to_s],
                    'releaseNotes' => [{ 'language' => 'en-US', 'text' => 'First Pleazyng native qualification test using the existing v3.0.7 release.' }] }]
  }
  api.call('put', "/edits/#{edit}/tracks/internal", staged)
  api.call('post', "/edits/#{edit}:validate")
  api.call('post', "/edits/#{edit}:commit?changesNotSentForReview=true")
  committed = true
  File.write(output, JSON.pretty_generate({ 'package' => package, 'version_code' => version, 'track' => 'internal',
    'status' => 'draft', 'original_aab_sha256' => expected, 'aab_uploaded' => false,
    'review_submitted' => false, 'distributed' => false, 'previous_internal' => track, 'staged_internal' => staged }) + "\n")
  puts 'Staged existing166 in internal draft; no upload, review submission or distribution'
ensure
  if edit && !committed
    begin
      api.call('delete', "/edits/#{edit}")
    rescue StandardError
      warn 'Uncommitted edit cleanup failed; it will expire without publication'
    end
  end
end
