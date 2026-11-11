# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require 'timeout'

# Verifies one immutable release IPA against the existing App Store Connect app.
# This module does not edit app versions, distribute to testers, or submit review.
module AppleStoreProcessing
  APP_ID = '6826955231'
  BUNDLE_ID = 'org.snapetech.pleazyng'
  STATES = %w[PROCESSING FAILED INVALID VALID].freeze
  PLATFORMS = {
    'ios' => ['iphoneos', 'IOS'],
    'appletvos' => ['appletvos', 'TV_OS']
  }.freeze

  def self.expected(plist:, platform:, release_tag:)
    source_platform, api_platform = PLATFORMS.fetch(platform) { raise ArgumentError, 'Unsupported Apple Store platform' }
    raise ArgumentError, 'Release tag must be an exact stable version' unless release_tag.match?(/\Av?\d+\.\d+\.\d+\z/)
    raise ArgumentError, 'IPA has no readable main app information' unless plist.is_a?(Hash)
    raise ArgumentError, 'IPA bundle identifier differs from the existing Apple app' unless plist['CFBundleIdentifier'] == BUNDLE_ID
    raise ArgumentError, 'IPA platform differs from the selected store channel' unless plist['DTPlatformName'] == source_platform

    version = plist['CFBundleShortVersionString']
    build = plist['CFBundleVersion']
    raise ArgumentError, 'IPA marketing version differs from the immutable release tag' unless version == release_tag.delete_prefix('v')
    raise ArgumentError, 'IPA build number must be a positive decimal integer' unless build.to_s.match?(/\A[1-9]\d*\z/)

    { app_id: APP_ID, bundle_id: BUNDLE_ID, platform: api_platform,
      version: version, build: build.to_s }
  end

  def self.verify_app!(app)
    raise ArgumentError, 'App Store Connect returned a different app record' unless app &&
      app.id.to_s == APP_ID && app.bundle_id == BUNDLE_ID
  end

  def self.exact_build(builds, expected)
    raise ArgumentError, 'App Store Connect returned an invalid build collection' unless builds.is_a?(Array)
    raise ArgumentError, 'App Store Connect returned duplicate build identities' if builds.length > 1
    return nil if builds.empty?

    build = builds.first
    raise ArgumentError, 'App Store Connect build identity differs from IPA' unless
      build.app_id.to_s == expected[:app_id] && build.bundle_id == expected[:bundle_id] &&
      build.app_version == expected[:version] && build.version.to_s == expected[:build] &&
      build.platform == expected[:platform] && build.id.to_s.match?(/\A[0-9A-Za-z-]{1,100}\z/)
    raise ArgumentError, 'App Store Connect returned an unknown processing state' unless STATES.include?(build.processing_state)

    build
  end

  def self.wait_for_valid(expected:, fetch:, upload:, clock:, pause:, timeout_seconds: 900, interval_seconds: 20)
    raise ArgumentError, 'Invalid processing wait limit' unless timeout_seconds.between?(1, 900) && interval_seconds.between?(1, 60)
    build = exact_build(fetch.call(expected), expected)
    if build && %w[FAILED INVALID].include?(build.processing_state)
      raise RuntimeError, "App Store Connect rejected build processing: #{build.processing_state}"
    end
    if build.nil?
      upload.call
      uploaded = true
    else
      uploaded = false
    end
    deadline = clock.call + timeout_seconds
    loop do
      build = exact_build(fetch.call(expected), expected)
      return [build, uploaded] if build && build.processing_state == 'VALID'
      if build && %w[FAILED INVALID].include?(build.processing_state)
        raise RuntimeError, "App Store Connect rejected build processing: #{build.processing_state}"
      end
      remaining = deadline - clock.call
      raise Timeout::Error, 'App Store Connect did not validate the exact build within the bounded wait' if remaining <= 0

      pause.call([interval_seconds, remaining].min)
    end
  end

  def self.receipt(expected:, build:, ipa_path:, release_tag:, run_id:, run_attempt:, uploaded:)
    raise ArgumentError, 'GitHub run identity is missing' unless run_id.to_s.match?(/\A[1-9]\d*\z/) &&
      run_attempt.to_s.match?(/\A[1-9]\d*\z/)
    raise ArgumentError, 'Only a valid processed build can produce a receipt' unless build.processing_state == 'VALID'

    { schema_version: 1, release_tag: release_tag, app_id: expected[:app_id],
      bundle_id: expected[:bundle_id], platform: expected[:platform],
      marketing_version: expected[:version], build_number: expected[:build],
      asc_build_id: build.id.to_s, processing_state: 'VALID',
      uploaded_at: build.uploaded_date&.to_s, ipa_sha256: Digest::SHA256.file(ipa_path).hexdigest,
      github_run_id: run_id.to_i, github_run_attempt: run_attempt.to_i,
      reused_existing_build: !uploaded,
      # ASC exposes version/build/processing state, not the uploaded IPA hash.
      # Preserve this distinction when reusing a pre-existing exact build.
      asc_linkage: uploaded ? 'transported_this_run' : 'existing_version_build_identity',
      verified_at: Time.now.utc.iso8601 }
  end
end
