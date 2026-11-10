#!/usr/bin/env ruby
# Deliver one authenticated release bundle; retain interrupted edits for retry.
require 'digest'
require 'json'
require 'net/http'
require 'stringio'
require 'uri'

module PlayDeliveryPolicy
  def self.plan(track, bundles, code, digest, status, fraction = nil)
    releases = track.fetch('releases', [])
    versions = releases.flat_map { |release| release.fetch('versionCodes', []).map { |value| Integer(value) } }
    return :superseded if versions.any? { |version| version > code }
    existing = bundles.find { |bundle| bundle.fetch('versionCode') == code }
    raise 'Existing Play bundle differs from the authenticated release' if existing && existing['sha256'] != digest
    matching = releases.any? { |release| release.fetch('versionCodes', []).map(&:to_i).include?(code) && release['status'] == status && (status != 'inProgress' || release['userFraction'] == fraction) }
    raise 'Active version has no verifiable bundle digest' if matching && !existing
    return :delivered if matching
    existing ? :assign : :upload
  end
end

class PlayApiError < StandardError
  attr_reader :status
  def initialize(status, message)
    @status = status.to_i
    super("Play HTTP #{status}: #{message}")
  end
end

class PlayReleasePublisher
  PACKAGE = 'org.snapetech.pleazyng'.freeze

  def initialize
    require 'googleauth'
    @path = ENV.fetch('PLAY_AAB_PATH')
    @receipt_path = ENV.fetch('PLAY_DELIVERY_RECEIPT')
    @code = Integer(ENV.fetch('PLAY_EXPECTED_VERSION_CODE'))
    @tag = ENV.fetch('PLAY_RELEASE_TAG')
    @track = ENV.fetch('PLAY_TRACK', 'internal')
    @status = ENV.fetch('PLAY_RELEASE_STATUS', 'completed')
    raise 'Unexpected release delivery target' unless @code >= 188 && @tag.match?(/\Av\d+\.\d+\.\d+\z/) && %w[internal alpha beta production].include?(@track) && %w[draft completed inProgress].include?(@status)
    if @status == 'inProgress'
      @fraction = Float(ENV.fetch('PLAY_ROLLOUT_FRACTION', '0.1'))
      raise 'Staged rollout fraction must be greater than zero and less than one' unless @fraction > 0 && @fraction < 1
    end
    @digest = Digest::SHA256.file(@path).hexdigest
    @receipt = { 'release_tag' => @tag, 'version_code' => @code, 'aab_sha256' => @digest,
                 'track' => @track, 'status' => @status, 'distributed' => false }
    @receipt['rollout_fraction'] = @fraction if @fraction
    if File.file?(@receipt_path)
      previous = JSON.parse(File.read(@receipt_path))
      if %w[release_tag version_code aab_sha256 track].all? { |key| previous[key] == @receipt[key] }
        if previous.dig('previous_edit', 'upload_attempted')
          @receipt['previous_edit'] = previous['previous_edit'].slice('id', 'expiry', 'upload_attempted')
        end
        pending = previous['pending_edit']
        if pending && pending['id'].to_s.match?(/\A\d+\z/) && pending['expiry'].to_i > Time.now.to_i
          @receipt['pending_edit'] = pending.slice('id', 'expiry', 'upload_attempted')
        elsif pending && pending['upload_attempted']
          @receipt['previous_edit'] = pending.slice('id', 'expiry', 'upload_attempted')
        end
      end
    end
    credentials = Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: StringIO.new(ENV.fetch('SUPPLY_JSON_KEY_DATA')),
      scope: 'https://www.googleapis.com/auth/androidpublisher'
    )
    @token = credentials.fetch_access_token!.fetch('access_token')
    @base = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/#{PACKAGE}"
    @committed = false
    save
  end

  def save
    File.write(@receipt_path, JSON.pretty_generate(@receipt) + "\n")
  end

  def parse(response)
    unless response.is_a?(Net::HTTPSuccess)
      message = (JSON.parse(response.body).dig('error', 'message') rescue 'No structured error')
      raise PlayApiError.new(response.code, message)
    end
    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  end

  def api(method, path, body = nil)
    uri = URI(@base + path)
    request = Net::HTTP.const_get(method.capitalize).new(uri)
    request['Authorization'] = "Bearer #{@token}"
    if body
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(body)
    end
    parse(Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 180) { |http| http.request(request) })
  end

  def begin_edit
    pending = @receipt['pending_edit']
    if pending
      @edit = pending.fetch('id')
      begin
        api('get', "/edits/#{@edit}")
        @recovered_edit = true
        return
      rescue PlayApiError => error
        raise unless [404, 409].include?(error.status)
        # The prior commit may have succeeded before the runner stopped.
        # Inspect committed tracks/bundles in a new edit, without blindly
        # repeating a potentially reserved upload.
        @receipt['previous_edit'] = pending
        @receipt.delete('pending_edit')
      end
    end
    edit = api('post', '/edits', {})
    @edit = edit.fetch('id')
    @receipt['pending_edit'] = { 'id' => @edit, 'expiry' => edit.fetch('expiryTimeSeconds').to_i,
                                 'upload_attempted' => false }
    save
    puts JSON.generate({ 'pending_edit' => @receipt['pending_edit'], 'version_code' => @code })
    $stdout.flush
  end

  def upload
    uri = URI("https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/#{PACKAGE}/edits/#{@edit}/bundles?uploadType=media")
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{@token}"
    request['Content-Type'] = 'application/octet-stream'
    request.content_length = File.size(@path)
    @receipt['pending_edit']['upload_attempted'] = true
    save
    result = File.open(@path, 'rb') do |file|
      request.body_stream = file
      parse(Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 600) { |http| http.request(request) })
    end
    raise 'Google returned another version or bundle digest' unless result['versionCode'] == @code && result['sha256'] == @digest
  end

  def run
    others_path = File.join(File.dirname(@receipt_path), 'pending-other-edits.json')
    if File.file?(others_path)
      others = JSON.parse(File.read(others_path))
      raise 'Unexpected pending Play edit inventory' unless others.is_a?(Array) && others.length <= 100
      others.each do |other|
        pending = other.fetch('pending_edit')
        next unless pending['id'].to_s.match?(/\A\d+\z/) && pending['expiry'].to_i > Time.now.to_i
        begin
          api('get', "/edits/#{pending['id']}")
        rescue PlayApiError => error
          next if [404, 409].include?(error.status)
          raise
        end
        raise "Unfinished Play delivery #{other['release_tag']}/#{other['track']} owns the app edit; recover it before starting another upload"
      end
    end
    begin_edit
    track = api('get', "/edits/#{@edit}/tracks/#{@track}")
    bundles = api('get', "/edits/#{@edit}/bundles").fetch('bundles', [])
    plan = PlayDeliveryPolicy.plan(track, bundles, @code, @digest, @status, @fraction)
    # A recovered edit exposes staged state, not proof of a committed release.
    plan = :assign if plan == :delivered && @recovered_edit
    @receipt['action'] = plan.to_s
    if %i[delivered superseded].include?(plan)
      @receipt['distributed'] = plan == :delivered && @track == 'internal' && @status == 'completed'
      @receipt['verified_track'] = track
      api('delete', "/edits/#{@edit}")
      @receipt.delete('pending_edit')
      @edit = nil
      save
      puts "Play #{@track}: #{plan} #{@code}; no bundle upload needed"
      return
    end
    if plan == :upload
      raise 'Prior upload edit expired or was invalidated; this version is not available for reassignment' if @receipt.dig('previous_edit', 'upload_attempted')
      upload
    end
    release = { 'name' => @tag, 'status' => @status, 'versionCodes' => [@code.to_s] }
    release['userFraction'] = @fraction if @fraction
    api('put', "/edits/#{@edit}/tracks/#{@track}", { 'track' => @track, 'releases' => [release] })
    api('post', "/edits/#{@edit}:commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW")
    @committed = true
    @receipt.delete('pending_edit')
    @receipt['committed'] = true
    save
    # Read the actual committed track in a separate, discarded verification edit.
    verification = api('post', '/edits', {}).fetch('id')
    begin
      current = api('get', "/edits/#{verification}/tracks/#{@track}")
      current_bundles = api('get', "/edits/#{verification}/bundles").fetch('bundles', [])
      verified = PlayDeliveryPolicy.plan(current, current_bundles, @code, @digest, @status, @fraction)
      raise 'Committed Play version/status was not verified' unless %i[delivered superseded].include?(verified)
      @receipt['verified_track'] = current
      @receipt['distributed'] = verified == :delivered && @track == 'internal' && @status == 'completed'
      @receipt['review_state'] = @track == 'internal' ? 'internal test distribution' : 'Google review/activation requires separate verification'
      save
    ensure
      api('delete', "/edits/#{verification}")
    end
    puts "Verified Play #{@track} assignment of #{@tag}, code #{@code}"
  ensure
    if @edit && !@committed && @receipt['pending_edit']
      if @receipt['pending_edit']['upload_attempted']
        save
        warn 'Recover the retained pending edit before another upload or Console mutation'
      else
        api('delete', "/edits/#{@edit}")
        @receipt.delete('pending_edit')
        save
      end
    end
  end
end

PlayReleasePublisher.new.run if $PROGRAM_NAME == __FILE__
