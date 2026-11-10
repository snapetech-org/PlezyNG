#!/usr/bin/env ruby
# Resolve an accepted first upload without assigning it to any testing/live track.
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
abort 'Refusing artifact-only commit with a live release or assigned167' unless tracks.all? { |track| track.fetch('releases', []).all? { |release| release['status'] == 'draft' && !release.fetch('versionCodes', []).map(&:to_i).include?(167) } }
receipt['registration_preflight'] = { 'original_edit_verified' => true, 'accepted_bundle_sha256_verified' => true,
  'no_track_contains_167' => true, 'all_existing_releases_draft' => true, 'tracks' => tracks }
File.write(path, JSON.pretty_generate(receipt) + "\n")
api.call('post', ':validate')
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
receipt['play_delivery'] = { 'version_code' => 167, 'bundle_registered' => true, 'track_assignment' => nil,
  'review_requested_by_client' => false, 'distributed' => false,
  'google_rejected_changes_not_sent_flag' => without_flag,
  'next' => 'Create the first internal release through Play Console using registered167' }
File.write(path, JSON.pretty_generate(receipt) + "\n")
puts 'Registered the exact accepted167 bundle only; no track assignment, review request or distribution'
