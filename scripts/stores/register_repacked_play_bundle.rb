#!/usr/bin/env ruby
# Complete only the accepted internal draft; no new edit/upload/rollout.
require 'googleauth'
require 'json'
require 'net/http'
require 'stringio'
require 'uri'

path = ENV.fetch('PLAY_REPACK_RECEIPT')
receipt = JSON.parse(File.read(path))
pending = receipt.fetch('pending_play_edit')
abort 'Expected accepted original-code167 repack' unless receipt['source_release'] == 'v3.0.7' && receipt['source_aab_sha256'] == 'eb4b5836a86df75297d9465a80fb251eb44e7e2d06aaeda1665e004a6b0445dd' && receipt['store_version_code'] == 167 && receipt['all_signed_payload_entries_verified'] == true && pending['upload_confirmed'] == true && pending['committed'] == false
edit = pending.fetch('id')
abort 'Invalid edit ID' unless edit.match?(/\A[0-9]+\z/)
abort 'Original edit expired; do not create or upload another automatically' if Time.now.to_i >= Integer(pending.fetch('expiry_time_seconds'))
credentials = Google::Auth::ServiceAccountCredentials.make_creds(
  json_key_io: StringIO.new(ENV.fetch('SUPPLY_JSON_KEY_DATA')),
  scope: 'https://www.googleapis.com/auth/androidpublisher'
)
token = credentials.fetch_access_token!.fetch('access_token')
base = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/org.snapetech.pleazyng/edits/#{edit}"
class PlayRegistrationError < StandardError; end
api = lambda do |method, suffix|
  uri = URI(base + suffix)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request['Authorization'] = "Bearer #{token}"
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 120) { |http| http.request(request) }
  unless response.is_a?(Net::HTTPSuccess)
    message = (JSON.parse(response.body).dig('error', 'message') rescue 'No structured error')
    raise PlayRegistrationError, "HTTP #{response.code}: #{message}"
  end
  response.body.empty? ? {} : JSON.parse(response.body)
end
info = api.call('get', '')
abort 'Pending edit identity changed' unless info['id'] == edit
bundles = api.call('get', '/bundles').fetch('bundles', [])
bundle = bundles.find { |item| item['versionCode'] == 167 }
abort 'Accepted167 missing or changed in original edit' unless bundle && bundle['sha256'] == receipt.fetch('signed_upload_sha256')
tracks = api.call('get', '/tracks').fetch('tracks', [])
receipt['registration_preflight'] = { 'original_edit_verified' => true, 'accepted_bundle_sha256_verified' => true,
  'tracks' => tracks }
File.write(path, JSON.pretty_generate(receipt) + "\n")
internal = tracks.find { |track| track['track'] == 'internal' }
releases = internal&.fetch('releases', []) || []
abort 'Expected exactly the existing167 internal draft' unless releases.length == 1 && releases[0]['status'] == 'draft' && releases[0].fetch('versionCodes', []).map(&:to_i) == [167]
abort 'Refusing to commit with another live or assigned167 release' unless tracks.all? { |track| track['track'] == 'internal' || track.fetch('releases', []).all? { |release| release['status'] == 'draft' && !release.fetch('versionCodes', []).map(&:to_i).include?(167) } }
# edits.validate returned403 for this first draft although upload and track PUT
# succeeded. Commit performs server validation too; use the normal commit path.
without_flag = false
begin
  api.call('post', ':commit?changesNotSentForReview=true&changesInReviewBehavior=ERROR_IF_IN_REVIEW')
rescue PlayRegistrationError => error
  # Google sometimes disallows this parameter for a new app. There is no track
  # assignment here and no active release: retry only that precise flag error.
  raise unless error.message.match?(/changesNotSentForReview.*must not be set/i)
  without_flag = true
  api.call('post', ':commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW')
end
receipt.delete('pending_play_edit')
receipt['play_delivery'] = { 'version_code' => 167, 'bundle_registered' => true, 'track_assignment' => 'internal', 'status' => 'draft',
  'distributed' => false, 'changes_not_sent_for_review_flag_applied' => !without_flag,
  'actual_console_review_state' => 'unverified; inspect separately before claiming submission state',
  'google_rejected_changes_not_sent_flag' => without_flag,
  'next' => 'Qualify Google-generated167 and inspect Console before activation' }
File.write(path, JSON.pretty_generate(receipt) + "\n")
puts 'Committed the exact existing167 internal draft; no rollout; verify Console review state separately'
