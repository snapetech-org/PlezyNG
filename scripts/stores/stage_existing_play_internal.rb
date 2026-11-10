#!/usr/bin/env ruby
# First-publication bootstrap only: attach immutable uploaded166 to an internal
# draft. No AAB upload, review submission, completed release, or production edit.
require 'googleauth'
require 'digest'
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
abort 'Unexpected immutable v3.0.7 AAB checksum' unless expected == 'eb4b5836a86df75297d9465a80fb251eb44e7e2d06aaeda1665e004a6b0445dd'
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
archived_apk_sha256 = nil
begin
  edit = api.call('post', '/edits', {}).fetch('id')
  bundles = api.call('get', "/edits/#{edit}/bundles").fetch('bundles', [])
  bundle = bundles.find { |item| item['versionCode'] == version }
  if bundle
    abort 'Original release AAB checksum does not match Play upload' unless bundle.fetch('sha256').downcase == expected
  else
    # A new edit copies deployed state, so the first unpublished, archived upload
    # can be absent here. Authenticate the already-qualified Google APK instead.
    # Its native libapp.so matches the immutable AAB on all three architectures;
    # see the first-publication QA release-code-parity.json receipt.
    catalog = api.call('get', "/generatedApks/#{version}")
    groups = catalog.fetch('generatedApks')
    abort 'Unexpected Google signing group for archived166' unless groups.length == 1 && groups[0].fetch('certificateSha256Hash').delete(':').downcase == '66eadd02162a81e1650bc62015bce8ff67729c0ddeb11a359a78d38799e80c22'
    download_id = URI.encode_www_form_component(groups[0].fetch('generatedUniversalApk').fetch('downloadId'))
    uri = URI(base + "/generatedApks/#{version}/downloads/#{download_id}:download?alt=media")
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{token}"
    digest = Digest::SHA256.new
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 180) do |http|
      http.request(request) do |response|
        abort "Archived APK download failed HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
        response.read_body { |chunk| digest.update(chunk) }
      end
    end
    archived_apk_sha256 = digest.hexdigest
    abort 'Archived Google APK differs from qualified immutable166' unless archived_apk_sha256 == 'c42cb09ea81ac84ea113d461a10d87d9718f887b3c99a4ce4b0a1086ad19df7d'
  end
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
  api.call('post', "/edits/#{edit}:commit?changesNotSentForReview=true&changesInReviewBehavior=ERROR_IF_IN_REVIEW")
  committed = true
  File.write(output, JSON.pretty_generate({ 'package' => package, 'version_code' => version, 'track' => 'internal',
    'status' => 'draft', 'original_aab_sha256' => expected, 'archived_google_apk_sha256' => archived_apk_sha256, 'aab_uploaded' => false,
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
