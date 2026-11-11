# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require_relative '../../fastlane/apple_store_processing'

class AppleStoreProcessingTest < Minitest::Test
  App = Struct.new(:id, :bundle_id)
  Build = Struct.new(:id, :app_id, :bundle_id, :app_version, :version,
                     :platform, :processing_state, :uploaded_date)

  def expected(platform = 'ios')
    AppleStoreProcessing.expected(plist: {
      'CFBundleIdentifier' => 'org.snapetech.pleazyng',
      'CFBundleShortVersionString' => '3.0.31', 'CFBundleVersion' => '190',
      'DTPlatformName' => platform == 'ios' ? 'iphoneos' : 'appletvos'
    }, platform: platform, release_tag: 'v3.0.31')
  end

  def build(identity, state)
    Build.new('a-build-id', identity[:app_id], identity[:bundle_id], identity[:version],
              identity[:build], identity[:platform], state, '2026-11-11T00:00:00Z')
  end

  def test_ipa_identity_must_match_existing_app_platform_and_tag
    assert_equal 'IOS', expected[:platform]
    assert_equal 'TV_OS', expected('appletvos')[:platform]
    AppleStoreProcessing.verify_app!(App.new('6826955231', 'org.snapetech.pleazyng'))
    assert_raises(ArgumentError) { AppleStoreProcessing.verify_app!(App.new('1', 'org.snapetech.pleazyng')) }
    base = { 'CFBundleIdentifier' => 'org.snapetech.pleazyng',
             'CFBundleShortVersionString' => '3.0.31', 'CFBundleVersion' => '190',
             'DTPlatformName' => 'iphoneos' }
    %w[CFBundleIdentifier CFBundleShortVersionString CFBundleVersion DTPlatformName].each do |key|
      bad = base.merge(key => 'wrong')
      assert_raises(ArgumentError, key) do
        AppleStoreProcessing.expected(plist: bad, platform: 'ios', release_tag: 'v3.0.31')
      end
    end
  end

  def test_existing_valid_exact_build_is_reused_without_upload
    identity = expected
    uploads = 0
    result, uploaded = AppleStoreProcessing.wait_for_valid(
      expected: identity, fetch: ->(_) { [build(identity, 'VALID')] },
      upload: -> { uploads += 1 }, clock: -> { 0 }, pause: ->(_) { flunk('no wait expected') }
    )
    assert_equal 'VALID', result.processing_state
    refute uploaded
    assert_equal 0, uploads
  end

  def test_absent_build_uploads_once_then_waits_for_valid_processing
    identity = expected('appletvos')
    sequence = [[], [], [build(identity, 'PROCESSING')], [build(identity, 'VALID')]]
    now = 0
    uploads = 0
    result, uploaded = AppleStoreProcessing.wait_for_valid(
      expected: identity, fetch: ->(_) { sequence.shift || flunk('extra query') },
      upload: -> { uploads += 1 }, clock: -> { now }, pause: ->(seconds) { now += seconds }
    )
    assert_equal 'VALID', result.processing_state
    assert uploaded
    assert_equal 1, uploads
    assert_equal 40, now
  end

  def test_failed_invalid_duplicate_and_mismatched_builds_are_rejected
    identity = expected
    %w[FAILED INVALID].each do |state|
      assert_raises(RuntimeError) do
        AppleStoreProcessing.wait_for_valid(expected: identity,
          fetch: ->(_) { [build(identity, state)] }, upload: -> { flunk('upload') },
          clock: -> { 0 }, pause: ->(_) { flunk('wait') })
      end
    end
    assert_raises(ArgumentError) { AppleStoreProcessing.exact_build([build(identity, 'VALID')] * 2, identity) }
    wrong = build(identity, 'VALID')
    wrong.platform = 'TV_OS'
    assert_raises(ArgumentError) { AppleStoreProcessing.exact_build([wrong], identity) }
  end

  def test_processing_wait_is_bounded_and_receipt_contains_only_public_identity
    identity = expected
    now = 0
    assert_raises(Timeout::Error) do
      AppleStoreProcessing.wait_for_valid(expected: identity,
        fetch: ->(_) { [build(identity, 'PROCESSING')] }, upload: -> { flunk('upload') },
        clock: -> { now }, pause: ->(seconds) { now += seconds }, timeout_seconds: 21)
    end
    Tempfile.create('apple-processing-', Dir.pwd) do |ipa|
      ipa.write('signed fixture bytes')
      ipa.flush
      receipt = AppleStoreProcessing.receipt(expected: identity, build: build(identity, 'VALID'),
        ipa_path: ipa.path, release_tag: 'v3.0.31', run_id: '123', run_attempt: '2', uploaded: false)
      assert_equal 'VALID', receipt[:processing_state]
      assert_equal Digest::SHA256.hexdigest('signed fixture bytes'), receipt[:ipa_sha256]
      assert_equal 123, receipt[:github_run_id]
      assert receipt[:reused_existing_build]
      assert_equal 'existing_version_build_identity', receipt[:asc_linkage]
      refute_match(/key|token|password|secret/i, receipt.keys.join(' '))
    end
  end
end
