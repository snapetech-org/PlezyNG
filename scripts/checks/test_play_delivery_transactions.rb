#!/usr/bin/env ruby
require 'tmpdir'
require_relative '../stores/publish_play_release'

# Credential lookup is a test double; no network or actual credential is read.
$LOADED_FEATURES << 'googleauth.rb'
module Google
  module Auth
    class ServiceAccountCredentials
      def self.make_creds(**_options) = new
      def fetch_access_token! = { 'access_token' => 'synthetic-test-token' }
    end
  end
end

class FakePlayPublisher < PlayReleasePublisher
  BUNDLE = 'authenticated signed bundle fixture'.freeze
  DIGEST = Digest::SHA256.hexdigest(BUNDLE)
  attr_reader :uploads, :updates, :deleted, :commit_attempts, :operations
  attr_accessor :fail_commit, :lose_commit_response

  def initialize(directory, track: {}, bundles: [], recovery: nil, fail_commit: false, lose_commit_response: false, other_pending: false, invalid_other: false, other_expiry: nil, status: 'completed', fraction: '0.1', version_code: 189)
    @committed_track, @committed_bundles = track, bundles
    @edits, @next_edit, @operations = {}, 20, []
    @uploads, @updates, @deleted, @commit_attempts = 0, 0, [], 0
    @fail_commit, @lose_commit_response = fail_commit, lose_commit_response
    bundle = File.join(directory, 'bundle.aab')
    receipt = File.join(directory, 'receipt.json')
    File.write(bundle, BUNDLE)
    if recovery
      previous = { 'release_tag' => 'v3.0.30', 'version_code' => version_code, 'aab_sha256' => DIGEST,
                   'track' => 'internal', 'status' => recovery.fetch(:status, 'completed'),
                   'pending_edit' => { 'id' => '17', 'expiry' => recovery.fetch(:expiry, Time.now.to_i + 600), 'upload_attempted' => true } }
      File.write(receipt, JSON.generate(previous))
      @edits['17'] = { track: recovery.fetch(:track, {}), bundles: recovery.fetch(:bundles, []) }
    end
    if other_pending
      File.write(File.join(directory, 'pending-other-edits.json'), JSON.generate([
        { 'release_tag' => 'v3.0.30', 'track' => 'alpha',
          'pending_edit' => { 'id' => '18', 'expiry' => other_expiry || Time.now.to_i + 600, 'upload_attempted' => true } }
      ]))
      @edits['18'] = { track: {}, bundles: [] } unless invalid_other
    end
    values = { 'PLAY_AAB_PATH' => bundle, 'PLAY_DELIVERY_RECEIPT' => receipt,
               'PLAY_EXPECTED_VERSION_CODE' => version_code.to_s, 'PLAY_RELEASE_TAG' => 'v3.0.30',
               'PLAY_TRACK' => 'internal', 'PLAY_RELEASE_STATUS' => status, 'PLAY_ROLLOUT_FRACTION' => fraction, 'SUPPLY_JSON_KEY_DATA' => '{}' }
    before = values.to_h { |key, _| [key, ENV[key]] }
    begin
      values.each { |key, value| ENV[key] = value }
      super()
    ensure
      before.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
  end

  def api(method, path, body = nil)
    @operations << [method, path]
    if method == 'post' && path == '/edits'
      @next_edit += 1
      @edits[@next_edit.to_s] = JSON.parse(JSON.generate({ 'track' => @committed_track, 'bundles' => @committed_bundles }), symbolize_names: false).transform_keys(&:to_sym)
      return { 'id' => @next_edit.to_s, 'expiryTimeSeconds' => (Time.now.to_i + 600).to_s }
    end
    identifier = path.match(%r{\A/edits/(\d+)})&.[](1)
    edit = @edits[identifier]
    raise PlayApiError.new(404, 'synthetic edit absent') unless edit
    if method == 'delete'
      @deleted << identifier
      @edits.delete(identifier)
      return {}
    end
    return {} if method == 'get' && path.match?(%r{\A/edits/\d+\z})
    return edit[:track] if method == 'get' && path.end_with?('/tracks/internal')
    return { 'bundles' => edit[:bundles] } if method == 'get' && path.end_with?('/bundles')
    if method == 'put'
      @updates += 1
      edit[:track] = body
      return body
    end
    if method == 'post' && path.include?(':commit')
      @commit_attempts += 1
      raise PlayApiError.new(503, 'synthetic commit interruption') if @fail_commit
      @committed_track, @committed_bundles = edit[:track], edit[:bundles]
      @edits.delete(identifier)
      raise PlayApiError.new(503, 'synthetic lost commit response') if @lose_commit_response
      return {}
    end
    raise "Unexpected API operation #{method} #{path}"
  end

  def upload
    @uploads += 1
    @receipt['pending_edit']['upload_attempted'] = true
    @edits.fetch(@edit)[:bundles] = [{ 'versionCode' => 189, 'sha256' => @digest }]
    save
  end
end

def assert(condition, message)
  raise message unless condition
end

def scenario(root, name)
  directory = File.join(root, name)
  Dir.mkdir(directory)
  yield directory
end

Dir.mktmpdir('play-delivery-test-') do |root|
  active = { 'releases' => [{ 'versionCodes' => ['189'], 'status' => 'completed' }] }
  bundle = [{ 'versionCode' => 189, 'sha256' => FakePlayPublisher::DIGEST }]
  scenario(root, 'fresh') do |directory|
    publisher = FakePlayPublisher.new(directory)
    publisher.run
    receipt = JSON.parse(File.read(File.join(directory, 'receipt.json')))
    assert(publisher.uploads == 1 && publisher.updates == 1, 'fresh delivery must upload and assign once')
    assert(receipt['distributed'] && receipt['committed'] && !receipt['pending_edit'], 'committed state must be independently verified')
  end
  scenario(root, 'already_delivered') do |directory|
    publisher = FakePlayPublisher.new(directory, track: active, bundles: bundle)
    publisher.run
    assert(publisher.uploads.zero? && publisher.updates.zero?, 'delivered bundle must be a no-op')
  end
  scenario(root, 'rejects_failed_version_code_188') do |directory|
    begin
      FakePlayPublisher.new(directory, version_code: 188)
      raise 'version code 188 unexpectedly passed'
    rescue RuntimeError => error
      raise unless error.message.include?('Unexpected release delivery target')
    end
  end
  scenario(root, 'newer_version') do |directory|
    publisher = FakePlayPublisher.new(directory, track: { 'releases' => [{ 'versionCodes' => ['190'] }] })
    publisher.run
    assert(publisher.uploads.zero? && publisher.updates.zero?, 'old releases must never roll back the track')
  end
  scenario(root, 'recover_uploaded_bundle') do |directory|
    publisher = FakePlayPublisher.new(directory, recovery: { bundles: bundle })
    publisher.run
    assert(publisher.uploads.zero? && publisher.updates == 1 && publisher.commit_attempts == 1, 'pending uploaded bundle must be committed without reupload')
  end
  scenario(root, 'staged_assignment_then_retry') do |directory|
    publisher = FakePlayPublisher.new(directory, fail_commit: true)
    begin
      publisher.run
      raise 'commit failure unexpectedly passed'
    rescue PlayApiError
      receipt = JSON.parse(File.read(File.join(directory, 'receipt.json')))
      assert(receipt.dig('pending_edit', 'upload_attempted') && publisher.deleted.empty?, 'failed commit must preserve its reserved upload')
    end
    publisher.fail_commit = false
    publisher.run
    receipt = JSON.parse(File.read(File.join(directory, 'receipt.json')))
    assert(publisher.uploads == 1 && publisher.commit_attempts == 2 && !publisher.deleted.include?('21'), 'staged assignment must be committed, never mistaken for committed delivery/deleted')
    assert(receipt['distributed'] && receipt['committed'], 'retry must verify committed state')
  end
  scenario(root, 'draft_to_completed_recovery') do |directory|
    draft = { 'releases' => [{ 'versionCodes' => ['189'], 'status' => 'draft' }] }
    publisher = FakePlayPublisher.new(directory, recovery: { status: 'draft', track: draft, bundles: bundle })
    publisher.run
    assert(publisher.uploads.zero? && publisher.commit_attempts == 1, 'target-status change must reuse the exact pending upload')
  end
  scenario(root, 'wrong_digest') do |directory|
    publisher = FakePlayPublisher.new(directory, bundles: [{ 'versionCode' => 189, 'sha256' => 'b' * 64 }])
    begin
      publisher.run
      raise 'wrong digest unexpectedly passed'
    rescue RuntimeError => error
      raise unless error.message.include?('differs from the authenticated')
      assert(publisher.uploads.zero? && publisher.updates.zero? && publisher.deleted.length == 1, 'digest mismatch must stop before upload/assignment')
    end
  end
  scenario(root, 'commit_succeeded_response_lost') do |directory|
    publisher = FakePlayPublisher.new(directory, lose_commit_response: true)
    begin
      publisher.run
      raise 'lost response unexpectedly passed'
    rescue PlayApiError
    end
    publisher.lose_commit_response = false
    publisher.run
    assert(publisher.uploads == 1 && publisher.commit_attempts == 1, 'already committed upload must be discovered without another upload/commit')
  end
  scenario(root, 'other_track_owns_valid_edit') do |directory|
    publisher = FakePlayPublisher.new(directory, other_pending: true)
    begin
      publisher.run
      raise 'other track edit unexpectedly invalidated'
    rescue RuntimeError => error
      raise unless error.message.include?('owns the app edit')
      assert(publisher.uploads.zero? && publisher.updates.zero? && publisher.deleted.empty?, 'another live track edit must remain untouched')
    end
  end
  scenario(root, 'stale_other_track_receipt') do |directory|
    publisher = FakePlayPublisher.new(directory, other_pending: true, invalid_other: true)
    publisher.run
    assert(publisher.uploads == 1, 'a nonexistent stale edit must not block a legitimate release')
  end
  scenario(root, 'near_expiry_own_upload') do |directory|
    publisher = FakePlayPublisher.new(directory, recovery: { expiry: Time.now.to_i + 30, bundles: bundle })
    publisher.run
    create = publisher.operations.index(['post', '/edits'])
    commit = publisher.operations.index { |method, path| method == 'post' && path.include?('/17:commit') }
    assert(publisher.uploads.zero? && commit && create > commit && !publisher.deleted.include?('17'), 'near-expiry upload must be recovered in its original edit before any new edit')
  end
  scenario(root, 'near_expiry_other_upload') do |directory|
    publisher = FakePlayPublisher.new(directory, other_pending: true, other_expiry: Time.now.to_i + 30)
    begin
      publisher.run
      raise 'near-expiry other edit unexpectedly invalidated'
    rescue RuntimeError => error
      raise unless error.message.include?('owns the app edit')
      assert(!publisher.operations.include?(['post', '/edits']) && publisher.deleted.empty?, 'other live upload remains protected until actual expiry')
    end
  end
  scenario(root, 'manual_staged_rollout_uses_same_safe_publisher') do |directory|
    partial = { 'releases' => [{ 'versionCodes' => ['189'], 'status' => 'inProgress', 'userFraction' => 0.1 }] }
    publisher = FakePlayPublisher.new(directory, track: partial, bundles: bundle, status: 'inProgress', fraction: '0.2')
    publisher.run
    assert(publisher.uploads.zero? && publisher.updates == 1, 'staged fraction change must safely reuse its authenticated bundle')
  end
  scenario(root, 'expired_reserved_edit') do |directory|
    publisher = FakePlayPublisher.new(directory, recovery: { expiry: Time.now.to_i - 10 })
    begin
      publisher.run
      raise 'expired upload unexpectedly repeated'
    rescue RuntimeError => error
      raise unless error.message.include?('expired or was invalidated')
      assert(publisher.uploads.zero?, 'expired reserved upload must never be blindly repeated')
    end
  end
end
puts 'Passed fifteen independent staged/committed Play delivery scenarios'
