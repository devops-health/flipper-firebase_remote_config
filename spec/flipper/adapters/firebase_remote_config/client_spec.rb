RSpec.describe Flipper::Adapters::FirebaseRemoteConfig::Client do
  subject(:client) do
    described_class.new(project_id: 'proj', credentials: credentials, http: http)
  end

  let(:http) { FakeHttp.new(FakeResponse.new(code: 200, body: '{"parameters":{}}')) }

  describe 'access token refresh' do
    context 'with no token yet' do
      let(:credentials) { FakeCredentials.new(access_token: nil) }

      it 'fetches one' do
        client.fetch_template
        expect(credentials.fetch_count).to eq(1)
      end
    end

    context 'with a live token' do
      let(:credentials) { FakeCredentials.new(access_token: 'live', expiring: false) }

      it 'reuses it' do
        2.times { client.fetch_template }
        expect(credentials.fetch_count).to eq(0)
      end

      it 'sends it as a bearer token' do
        client.fetch_template
        expect(http.requests.last['Authorization']).to eq('Bearer live')
      end
    end

    context 'with a token about to expire' do
      let(:credentials) { FakeCredentials.new(access_token: 'stale', expiring: true) }

      it 'refreshes rather than sending the expiring token' do
        client.fetch_template
        expect(credentials.fetch_count).to eq(1)
        expect(http.requests.last['Authorization']).to eq('Bearer token-1')
      end
    end

    context 'with credentials that do not implement expires_within?' do
      let(:credentials) { FakeCredentialsWithoutExpiry.new(access_token: 'live') }

      it 'falls back to the presence check' do
        expect { client.fetch_template }.not_to raise_error
        expect(credentials.fetch_count).to eq(0)
      end
    end

    it 'refreshes only once when threads race for a token' do
      creds = FakeCredentials.new(access_token: nil)
      racing = described_class.new(project_id: 'proj', credentials: creds, http: http)

      threads = Array.new(8) { Thread.new { racing.fetch_template } }
      threads.each(&:join)

      expect(creds.fetch_count).to eq(1)
    end
  end
  describe '#latest_version' do
    let(:credentials) { FakeCredentials.new(access_token: 'live') }

    def client_for(body)
      described_class.new(
        project_id: 'proj',
        credentials: credentials,
        http: FakeHttp.new(FakeResponse.new(code: 200, body: body))
      )
    end

    it 'returns the latest published version number' do
      client = client_for(JSON.generate('versions' => [{ 'versionNumber' => '7' }]))
      expect(client.latest_version).to eq(7)
    end

    it 'asks listVersions for a single version rather than the template' do
      client = client_for(JSON.generate('versions' => []))
      client.latest_version
      path = client.instance_variable_get(:@http).requests.last.path
      expect(path).to end_with('/remoteConfig:listVersions?pageSize=1')
    end

    it 'returns nil when the project has never published a template' do
      expect(client_for('{}').latest_version).to be_nil
    end
  end
end
