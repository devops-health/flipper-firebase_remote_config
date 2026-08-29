require 'json'
require 'net/http'
require 'uri'
require 'googleauth'

module Flipper
  module Adapters
    class FirebaseRemoteConfig
      class Error < StandardError; end
      class ETagMismatch < Error; end

      SCOPE        = 'https://www.googleapis.com/auth/firebase.remoteconfig'.freeze
      API_HOST     = 'firebaseremoteconfig.googleapis.com'.freeze
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 15
      # Refresh the access token this many seconds before it actually expires.
      TOKEN_REFRESH_WINDOW = 60

      # Thin REST wrapper around the Firebase Remote Config v1 API.
      #
      # Why hand-rolled instead of a generated client: there is no published
      # service gem for `firebaseremoteconfig_v1` — neither bundled inside the
      # (deprecated) `google-api-client` umbrella, nor as a stand-alone
      # `google-apis-firebaseremoteconfig_v1`. We use `googleauth` directly
      # for the OAuth2 service-account flow, and Net::HTTP for the two
      # endpoints we actually need.
      class Client
        attr_reader :project_id

        def initialize(project_id:, credentials: nil, http: nil)
          @project_id  = project_id
          @credentials = build_credentials(credentials)
          @http        = http # injection seam for tests
          @token_mutex = Mutex.new
        end

        # Returns [template_hash, etag_string]. The template is the parsed JSON
        # body as a Hash; etag is the opaque string from the ETag response
        # header, which the server demands back on the next write.
        def fetch_template
          response = request(:get, template_path)
          ensure_success!(response)
          [JSON.parse(response.body), response['ETag']]
        end

        # The version number of the most recently published template, or nil if
        # the project has never published one.
        #
        # This is the cheap change probe: it returns one version's metadata
        # rather than the whole template, so a background poller can call it
        # often. Note that `If-None-Match` is *not* honoured on the template GET
        # — that was tested against a live project and always returns 200 with a
        # full body — so there is no 304 shortcut to use instead.
        def latest_version
          response = request(:get, "#{template_path}:listVersions?pageSize=1")
          ensure_success!(response)
          version = (JSON.parse(response.body)['versions'] || []).first
          version && version['versionNumber'].to_i
        end

        # Publishes a modified template. Raises ETagMismatch on 409/412 so the
        # adapter can reload and retry; raises Error on any other failure.
        def publish_template(template, etag)
          response = request(
            :put,
            template_path,
            body: JSON.generate(template),
            headers: { 'Content-Type' => 'application/json; UTF-8',
                       'If-Match' => etag || '*' }
          )
          raise ETagMismatch, response.body if etag_conflict?(response)

          ensure_success!(response)
          response
        end

        private

        def template_path
          "/v1/projects/#{@project_id}/remoteConfig"
        end

        def request(method, path, body: nil, headers: {})
          uri = URI("https://#{API_HOST}#{path}")
          req_class = method == :get ? Net::HTTP::Get : Net::HTTP::Put
          req = req_class.new(uri)
          headers.each { |k, v| req[k] = v }
          # Deliberately not calling @credentials.apply! here. googleauth's
          # apply! refreshes the token itself (BaseClient#apply! ->
          # fetch_access_token! if needs_access_token?), which would happen
          # outside @token_mutex and on the same 60s window fetch_access_token
          # uses — leaving the refresh unserialized and token_stale? never true.
          # It also wrote into a throwaway hash whose result was discarded.
          token = fetch_access_token
          req['Authorization'] = "Bearer #{token}" if token
          req.body = body if body

          http_for(uri).request(req)
        end

        def http_for(uri)
          return @http if @http

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = OPEN_TIMEOUT
          http.read_timeout = READ_TIMEOUT
          http
        end

        # A process that outlives the ~1h token must refresh it, so check
        # expiry rather than mere presence. The mutex keeps a listener thread
        # and request threads from refreshing at the same time.
        def fetch_access_token
          return nil unless @credentials

          @token_mutex.synchronize do
            @credentials.fetch_access_token! if token_stale?
          end
          @credentials.access_token
        end

        # Credentials that don't implement expires_within? (a static token, a
        # test double) only get the presence check.
        def token_stale?
          return true if @credentials.access_token.nil?
          return false unless @credentials.respond_to?(:expires_within?)

          @credentials.expires_within?(TOKEN_REFRESH_WINDOW)
        end

        def build_credentials(credentials)
          case credentials
          when String
            ::Google::Auth::ServiceAccountCredentials.make_creds(
              json_key_io: File.open(credentials),
              scope: SCOPE
            )
          when IO, StringIO
            ::Google::Auth::ServiceAccountCredentials.make_creds(
              json_key_io: credentials,
              scope: SCOPE
            )
          when nil
            ::Google::Auth.get_application_default([SCOPE])
          else
            credentials
          end
        end

        def etag_conflict?(response)
          [409, 412].include?(response.code.to_i)
        end

        def ensure_success!(response)
          return if (200..299).cover?(response.code.to_i)

          raise Error,
                "Firebase Remote Config API error #{response.code}: #{response.body}"
        end
      end
    end
  end
end
