#!/usr/bin/env ruby
# Fetch Google-generated signed APKs for an already uploaded version. No edits,
# uploads, track mutations, review submission, or credential files are created.
require 'digest'
require 'fileutils'
require 'googleauth'
require 'json'
require 'net/http'
require 'stringio'
require 'uri'

package = 'org.snapetech.pleazyng'
version = ENV.fetch('PLAY_VERSION_CODE')
abort 'PLAY_VERSION_CODE must be a positive integer' unless version.match?(/\A[1-9][0-9]*\z/)
output = File.expand_path(ENV.fetch('PLAY_QUALIFICATION_OUTPUT'))
FileUtils.mkdir_p(output)
credentials = Google::Auth::ServiceAccountCredentials.make_creds(
  json_key_io: StringIO.new(ENV.fetch('SUPPLY_JSON_KEY_DATA')),
  scope: 'https://www.googleapis.com/auth/androidpublisher'
)
token = credentials.fetch_access_token!.fetch('access_token')
base = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/#{package}"
request = lambda do |path, destination = nil, allow_unavailable: false|
  uri = URI(base + path)
  connection = Net::HTTP.new(uri.host, uri.port)
  connection.use_ssl = true
  connection.open_timeout = 30
  connection.read_timeout = 180
  get = Net::HTTP::Get.new(uri)
  get['Authorization'] = "Bearer #{token}"
  response_data = nil
  connection.start do |http|
    http.request(get) do |response|
      if allow_unavailable && !response.is_a?(Net::HTTPSuccess)
        response_data = { 'unavailable' => true, 'http_status' => response.code.to_i }
        next
      end
      abort "Play API request failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      if destination
        File.open(destination, 'wb') { |file| response.read_body { |chunk| file.write(chunk) } }
      else
        body = response.body.to_s
        if allow_unavailable && body.strip.empty?
          response_data = { 'unavailable' => true, 'http_status' => response.code.to_i, 'reason' => 'empty_response' }
        else
          response_data = JSON.parse(body)
        end
      end
    end
  end
  response_data
end
lifecycle = %w[internal alpha].to_h do |track|
  [track, request.call("/tracks/#{track}/releases", nil, allow_unavailable: true)]
end
File.write(File.join(output, 'play-release-lifecycle.json'), JSON.pretty_generate(lifecycle) + "\n")
catalog = request.call("/generatedApks/#{version}")
File.write(File.join(output, 'generated-apks.json'), JSON.pretty_generate(catalog) + "\n")
receipt = {
  'package' => package, 'version_code' => version.to_i,
  'source' => 'Google Play generatedapks API for the existing uploaded bundle',
  'store_state_mutated' => false, 'purchase_restore_qualified' => false,
  'reviewer_grant_device_qualified' => false, 'apks' => [], 'emulator_test_apks' => []
}
catalog.fetch('generatedApks').each_with_index do |group, index|
  universal = group['generatedUniversalApk']
  next unless universal
  download_id = URI.encode_www_form_component(universal.fetch('downloadId'))
  filename = "play-signed-universal-#{index}.apk"
  request.call("/generatedApks/#{version}/downloads/#{download_id}:download?alt=media", File.join(output, filename))
  receipt['apks'] << {
    'file' => filename, 'sha256' => Digest::SHA256.file(File.join(output, filename)).hexdigest,
    'expected_signing_certificate_sha256' => group.fetch('certificateSha256Hash')
  }
end
if ENV['PLAY_FETCH_EMULATOR_SPLITS'] == 'true'
  group = catalog.fetch('generatedApks').first
  variants = group.fetch('targetingInfo').fetch('variant').filter_map do |variant|
    minimum = variant.fetch('targeting').fetch('sdkVersionTargeting').fetch('value').map { |value| value.fetch('min') }.max
    [minimum, variant.fetch('variantNumber')] if minimum <= 36
  end
  abort 'No Android 36 native test variant in Google targeting metadata' if variants.empty?
  minimum, variant_id = variants.max_by(&:first)
  required = ['', 'config.x86_64', 'config.xxhdpi', 'config.en']
  splits = group.fetch('unprotectedGeneratedSplitApks').select do |split|
    split.fetch('variantId') == variant_id && split.fetch('moduleName') == 'base' && required.include?(split.fetch('splitId', ''))
  end
  abort 'Incomplete or duplicate native test split set' unless splits.map { |split| split.fetch('splitId', '') }.sort == required.sort
  splits.each do |split|
    identifier = split.fetch('splitId', 'base')
    filename = "emulator-test-#{identifier}.apk"
    download_id = URI.encode_www_form_component(split.fetch('downloadId'))
    request.call("/generatedApks/#{version}/downloads/#{download_id}:download?alt=media", File.join(output, filename))
    receipt['emulator_test_apks'] << {
      'file' => filename, 'sha256' => Digest::SHA256.file(File.join(output, filename)).hexdigest,
      'expected_signing_certificate_sha256' => group.fetch('certificateSha256Hash'),
      'variant' => variant_id, 'minimum_sdk' => minimum,
      'source' => 'Google-provided unprotectedGeneratedSplitApks for isolated emulator QA only'
    }
  end
end
File.write(File.join(output, 'play-qualification.json'), JSON.pretty_generate(receipt) + "\n")
abort 'No universal APK generated; inspect targeting metadata before selecting native splits' if receipt['apks'].empty?
puts "Fetched #{receipt['apks'].length} signed universal APK(s); no publication state changed"
