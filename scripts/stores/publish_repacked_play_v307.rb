#!/usr/bin/env ruby
# One-off existing-release repack: internal draft only, no review or rollout.
require 'digest'
require 'googleauth'
require 'json'
require 'net/http'
require 'stringio'
require 'uri'

package = 'org.snapetech.pleazyng'
receipt_path = ENV.fetch('PLAY_REPACK_RECEIPT')
receipt = JSON.parse(File.read(receipt_path))
bundle_path = ENV.fetch('PLAY_REPACK_AAB')
abort 'Unexpected repack provenance' unless receipt['source_release'] == 'v3.0.7' && receipt['source_aab_sha256'] == 'eb4b5836a86df75297d9465a80fb251eb44e7e2d06aaeda1665e004a6b0445dd' && receipt['store_version_code'] == 167 && receipt['all_signed_payload_entries_verified'] == true && receipt['compiled_code_and_other_resources_identical'] == true
abort 'Signed repack checksum mismatch' unless Digest::SHA256.file(bundle_path).hexdigest == receipt.fetch('signed_upload_sha256')
credentials = Google::Auth::ServiceAccountCredentials.make_creds(
  json_key_io: StringIO.new(ENV.fetch('SUPPLY_JSON_KEY_DATA')),
  scope: 'https://www.googleapis.com/auth/androidpublisher'
)
token = credentials.fetch_access_token!.fetch('access_token')
base = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/#{package}"
parse = lambda do |response|
  unless response.is_a?(Net::HTTPSuccess)
    message = (JSON.parse(response.body).dig('error', 'message') rescue 'No structured error')
    raise "Play HTTP #{response.code}: #{message}"
  end
  response.body.to_s.empty? ? {} : JSON.parse(response.body)
end
api = lambda do |method, path, body = nil|
  uri = URI(base + path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request['Authorization'] = "Bearer #{token}"
  if body
    request['Content-Type'] = 'application/json'
    request.body = JSON.generate(body)
  end
  parse.call(Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 120) { |http| http.request(request) })
end
edit = nil
upload_attempted = false
upload_confirmed = false
committed = false
begin
  edit_info = api.call('post', '/edits', {})
  edit = edit_info.fetch('id')
  receipt['pending_play_edit'] = { 'id' => edit, 'expiry_time_seconds' => edit_info.fetch('expiryTimeSeconds'),
    'version_code' => 167, 'committed' => false, 'upload_attempted' => false }
  File.write(receipt_path, JSON.pretty_generate(receipt) + "\n")
  # Non-secret transaction identifiers also reach the streamed CI log before
  # mutation, so an abruptly lost runner does not hide the recovery target.
  puts JSON.generate({ 'pending_play_edit' => receipt['pending_play_edit'] })
  $stdout.flush
  track = api.call('get', "/edits/#{edit}/tracks/internal")
  releases = track.fetch('releases', [])
  abort 'Refusing to replace an unrelated or active internal release' unless releases.all? { |release| release['status'] == 'draft' && (release.fetch('versionCodes', []).map(&:to_i) - [167]).empty? }
  existing = api.call('get', "/edits/#{edit}/bundles").fetch('bundles', []).find { |item| item['versionCode'] == 167 }
  if existing
    abort 'Existing167 does not match this exact signed repack' unless existing['sha256'] == receipt['signed_upload_sha256']
  else
    uri = URI("https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/#{package}/edits/#{edit}/bundles?uploadType=media")
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{token}"
    request['Content-Type'] = 'application/octet-stream'
    request.content_length = File.size(bundle_path)
    upload_attempted = true
    receipt['pending_play_edit']['upload_attempted'] = true
    File.write(receipt_path, JSON.pretty_generate(receipt) + "\n")
    result = File.open(bundle_path, 'rb') do |file|
      request.body_stream = file
      parse.call(Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 600) { |http| http.request(request) })
    end
    upload_confirmed = true
    abort 'Google returned an unexpected uploaded bundle' unless result['versionCode'] == 167 && result['sha256'] == receipt['signed_upload_sha256']
  end
  api.call('put', "/edits/#{edit}/tracks/internal", {
    'track' => 'internal', 'releases' => [{ 'name' => '3.0.7 - store repack167', 'status' => 'draft',
      'versionCodes' => ['167'], 'releaseNotes' => [{ 'language' => 'en-US',
        'text' => 'First Pleazyng test. Original v3.0.7 application code; store-only version-code correction.' }] }]
  })
  api.call('post', "/edits/#{edit}:commit?changesNotSentForReview=true&changesInReviewBehavior=ERROR_IF_IN_REVIEW")
  committed = true
  receipt.delete('pending_play_edit')
  receipt['play_delivery'] = { 'track' => 'internal', 'status' => 'draft', 'version_code' => 167,
    'review_submitted' => false, 'distributed' => false, 'new_application_build' => false }
  File.write(receipt_path, JSON.pretty_generate(receipt) + "\n")
  puts 'Existing v3.0.7 code uploaded as167 and saved in internal draft; no review or rollout'
ensure
  if edit && !committed
    if upload_attempted
      # Preserve a recoverable transaction instead of discarding a newly reserved
      # version. Do not make Console changes until this edit is resolved.
      receipt['pending_play_edit']['upload_confirmed'] = upload_confirmed
      File.write(receipt_path, JSON.pretty_generate(receipt) + "\n")
      warn 'Upload attempted but edit remains uncommitted; recover using retained receipt before Console changes'
    else
      begin
        api.call('delete', "/edits/#{edit}")
        receipt.delete('pending_play_edit')
        File.write(receipt_path, JSON.pretty_generate(receipt) + "\n")
      rescue StandardError
        warn 'Unused edit cleanup failed; no bundle was uploaded'
      end
    end
  end
end
