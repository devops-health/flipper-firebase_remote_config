require 'spec_helper'

RSpec.describe Flipper::Adapters::FirebaseRemoteConfig do
  let(:client)  { FakeClient.new }
  let(:adapter) { described_class.new(client: client, cache_ttl: 0) }
  let(:flipper) { Flipper.new(adapter) }
  let(:feature) { flipper[:search] }

  describe '#name' do
    it 'identifies the adapter' do
      expect(adapter.name).to eq(:firebase_remote_config)
    end
  end

  describe 'feature lifecycle' do
    it 'starts with no features' do
      expect(adapter.features).to be_empty
    end

    it 'add / features / remove round-trip' do
      adapter.add(feature)
      expect(adapter.features).to contain_exactly('search')

      adapter.remove(feature)
      expect(adapter.features).to be_empty
    end

    it 'remove also drops gate state' do
      flipper.enable(:search)
      adapter.remove(feature)
      expect(adapter.get(feature)[:boolean]).to be_nil
    end

    it 'clear resets gates but keeps the feature registered' do
      flipper.enable(:search)
      adapter.clear(feature)
      expect(adapter.features).to include('search')
      expect(adapter.get(feature)[:boolean]).to be_nil
    end
  end

  describe 'boolean gate' do
    it 'enable sets boolean=true' do
      flipper.enable(:search)
      expect(adapter.get(feature)[:boolean]).to eq('true')
    end

    it 'disable wipes all gates' do
      flipper.enable_actor(:search, Flipper::Actor.new('1'))
      flipper.enable_percentage_of_time(:search, 25)
      flipper.disable(:search)
      gates = adapter.get(feature)
      expect(gates[:boolean]).to be_nil
      expect(gates[:actors]).to be_empty
      expect(gates[:percentage_of_time]).to be_nil
    end
  end

  describe 'set gates' do
    it 'tracks actor adds and removes' do
      flipper.enable_actor(:search, Flipper::Actor.new('1'))
      flipper.enable_actor(:search, Flipper::Actor.new('2'))
      expect(adapter.get(feature)[:actors]).to eq(Set.new(%w[1 2]))

      flipper.disable_actor(:search, Flipper::Actor.new('1'))
      expect(adapter.get(feature)[:actors]).to eq(Set.new(%w[2]))
    end

    it 'tracks groups' do
      Flipper.register(:admins) { |_actor| true }
      flipper.enable_group(:search, :admins)
      expect(adapter.get(feature)[:groups]).to eq(Set.new(%w[admins]))
    ensure
      Flipper.unregister_groups
    end
  end

  describe 'integer gates' do
    it 'stores percentage_of_actors' do
      flipper.enable_percentage_of_actors(:search, 42)
      expect(adapter.get(feature)[:percentage_of_actors]).to eq('42')
    end

    it 'stores percentage_of_time' do
      flipper.enable_percentage_of_time(:search, 75)
      expect(adapter.get(feature)[:percentage_of_time]).to eq('75')
    end
  end

  describe '#get_all and #get_multi' do
    it 'returns gate state for every known feature' do
      flipper.enable(:search)
      flipper.enable_percentage_of_time(:checkout, 50)

      all = adapter.get_all
      expect(all.keys).to contain_exactly('search', 'checkout')
      expect(all['search'][:boolean]).to eq('true')
      expect(all['checkout'][:percentage_of_time]).to eq('50')
    end

    it 'get_multi returns the requested subset' do
      flipper.enable(:search)
      flipper.enable(:checkout)
      result = adapter.get_multi([flipper[:search]])
      expect(result.keys).to eq(['search'])
    end

    it 'get on unknown feature returns default config' do
      gates = adapter.get(flipper[:nope])
      expect(gates[:boolean]).to be_nil
      expect(gates[:actors]).to be_empty
    end
  end

  describe 'ETag handling' do
    it 'retries once when the template changed between fetch and publish' do
      flipper.enable(:search) # warms the cache

      # Adapter has cached template+etag. Another process publishes, bumping
      # the server ETag. The adapter's next publish should fail, reload, and
      # succeed on retry.
      client.bump_etag!
      adapter.reload! # ensure we re-read after the external write

      expect { flipper.enable(:checkout) }.not_to raise_error
      expect(adapter.features).to include('search', 'checkout')
    end

    it 'gives up after one retry' do
      flipper.enable(:search)
      # Force every publish to raise — exceeds the single retry budget.
      allow(client).to receive(:publish_template)
        .and_raise(Flipper::Adapters::FirebaseRemoteConfig::ETagMismatch, 'stale')

      expect { flipper.enable(:checkout) }
        .to raise_error(Flipper::Adapters::FirebaseRemoteConfig::ETagMismatch)
    end
  end

  describe 'caching' do
    it 'serves repeated reads from cache within the TTL' do
      cached = described_class.new(client: client, cache_ttl: 60)
      expect(client).to receive(:fetch_template).once.and_call_original
      3.times { cached.features }
    end

    it 'reload! forces a refetch' do
      cached = described_class.new(client: client, cache_ttl: 60)
      cached.features
      cached.reload!
      expect(client).to receive(:fetch_template).and_call_original
      cached.features
    end
  end

  describe 'parameter naming and value format' do
    def template
      client.fetch_template.first
    end

    # A blob written by this adapter always has boolean as "true" or nil, so
    # only a human editing in the console produces "false" here — and the
    # console is now a first-class way to author flags.
    it 'does not switch a feature on when a console blob narrows to boolean-only' do
      external, etag = client.fetch_template
      external['parameters']['search'] = {
        'valueType' => 'JSON',
        'defaultValue' => { 'value' => JSON.generate(
          'boolean' => 'false', 'actors' => ['1'], 'groups' => [],
          'percentage_of_actors' => nil, 'percentage_of_time' => nil
        ) }
      }
      client.publish_template(external, etag)
      adapter.reload!

      feature.disable_actor(Flipper::Actor.new('1'))

      param = template['parameters']['search']
      expect(param.dig('defaultValue', 'value')).to eq('false')
      expect(flipper[:search].enabled?(Flipper::Actor.new('2'))).to be(false)
    end

    it 'names the parameter for the feature key, with no prefix' do
      feature.enable
      expect(template['parameters'].keys).to eq(['search'])
    end

    it 'writes no index parameter' do
      feature.enable
      expect(template['parameters'].keys).to all(satisfy { |k| !k.include?('index') })
    end

    it 'stores a simple on/off feature as a real BOOLEAN parameter' do
      feature.enable
      param = template['parameters']['search']
      expect(param['valueType']).to eq('BOOLEAN')
      expect(param.dig('defaultValue', 'value')).to eq('true')
    end

    it 'stores a disabled feature as BOOLEAN false' do
      feature.enable
      feature.disable
      param = template['parameters']['search']
      expect(param['valueType']).to eq('BOOLEAN')
      expect(param.dig('defaultValue', 'value')).to eq('false')
    end

    it 'round-trips a disabled feature back to the default config' do
      feature.enable
      feature.disable
      expect(adapter.get(feature)).to eq(
        boolean: nil, actors: Set.new, groups: Set.new,
        percentage_of_actors: nil, percentage_of_time: nil
      )
    end

    it 'falls back to JSON once a feature uses a gate clients cannot evaluate' do
      feature.enable_actor(Flipper::Actor.new('1'))
      param = template['parameters']['search']
      expect(param['valueType']).to eq('JSON')
      expect(JSON.parse(param.dig('defaultValue', 'value'))['actors']).to eq(['1'])
    end

    it 'warns when a feature stops being readable by clients' do
      feature.enable
      expect { feature.enable_actor(Flipper::Actor.new('1')) }
        .to output(/no longer a plain boolean/).to_stderr
    end
  end

  describe 'parameters the adapter does not own' do
    def console_parameter
      external, etag = client.fetch_template
      external['parameters']['search'] = {
        'valueType' => 'BOOLEAN',
        'description' => 'owned by the mobile team',
        'defaultValue' => { 'value' => 'false' },
        'conditionalValues' => { 'ios_beta' => { 'value' => 'true' } }
      }
      client.publish_template(external, etag)
      adapter.reload!
    end

    it 'keeps description and conditionalValues when flipping a console feature' do
      console_parameter
      feature.enable

      param = client.fetch_template.first['parameters']['search']
      expect(param['description']).to eq('owned by the mobile team')
      expect(param['conditionalValues']).to eq('ios_beta' => { 'value' => 'true' })
      expect(param.dig('defaultValue', 'value')).to eq('true')
    end

    it 'drops conditionalValues on a type change, and says so' do
      console_parameter

      expect { feature.enable_actor(Flipper::Actor.new('1')) }
        .to output(/conditionalValues were dropped/).to_stderr

      param = client.fetch_template.first['parameters']['search']
      expect(param).not_to have_key('conditionalValues')
      expect(param['description']).to eq('owned by the mobile team')
    end
  end

  describe 'writes that change nothing' do
    it 'does not spend a publish re-enabling an already-enabled feature' do
      feature.enable
      expect { 2.times { feature.enable } }.not_to change(client, :publish_calls)
    end
  end

  describe 'gates this adapter cannot persist' do
    it 'raises rather than silently discarding an expression gate' do
      expect { feature.enable(Flipper.property(:plan).eq('basic')) }
        .to raise_error(ArgumentError, /Unsupported gate :expression/)
    end
  end

  describe 'disabling a percentage gate' do
    # Flipper stores "0" rather than clearing the gate, and "0" means the same
    # as absent. Treating it as present pushed the feature into the JSON blob,
    # turning it off for every client while the backend still said enabled.
    it 'leaves an otherwise boolean-only feature readable by clients' do
      feature.enable
      feature.disable_percentage_of_actors

      param = client.fetch_template.first['parameters']['search']
      expect(param['valueType']).to eq('BOOLEAN')
      expect(param.dig('defaultValue', 'value')).to eq('true')
      expect(feature).to be_enabled
    end
  end

  describe 'recognising which parameters are features' do
    def publish(parameters)
      template, etag = client.fetch_template
      template['parameters'] = parameters
      client.publish_template(template, etag)
    end

    it 'treats a BOOLEAN parameter created outside the adapter as a feature' do
      publish('created_in_console' => {
                'valueType' => 'BOOLEAN',
                'defaultValue' => { 'value' => 'true' }
              })

      expect(adapter.features).to include('created_in_console')
      expect(flipper[:created_in_console]).to be_enabled
    end

    it 'ignores the app own non-boolean parameters' do
      publish('welcome_message' => {
                'valueType' => 'STRING',
                'defaultValue' => { 'value' => 'Hello' }
              })

      expect(adapter.features).to be_empty
    end

    it 'still recognises a JSON gate blob' do
      publish('beta_ui' => {
                'valueType' => 'JSON',
                'defaultValue' => {
                  'value' => JSON.generate(
                    'boolean' => nil, 'actors' => ['1'], 'groups' => [],
                    'percentage_of_actors' => nil, 'percentage_of_time' => nil
                  )
                }
              })

      expect(adapter.features).to include('beta_ui')
    end

    it 'ignores app JSON that merely shares a key name with a gate' do
      publish('audience_config' => {
                'valueType' => 'JSON',
                'defaultValue' => {
                  'value' => JSON.generate('groups' => %w[beta internal])
                }
              })

      expect(adapter.features).to be_empty
    end
  end
  describe 'thread safety' do
    let(:adapter) { described_class.new(client: client, cache_ttl: 60) }

    it 'keeps a failed write out of the cache readers see' do
      feature.enable
      adapter.features # prime the cache

      allow(client).to receive(:publish_template)
        .and_raise(Flipper::Adapters::FirebaseRemoteConfig::Error, 'boom')

      expect { flipper[:other].enable }
        .to raise_error(Flipper::Adapters::FirebaseRemoteConfig::Error)
      expect(adapter.features).not_to include('other')
    end

    it 'fetches once when threads race on a cold cache' do
      expect(client).to receive(:fetch_template).once.and_call_original

      threads = Array.new(8) { Thread.new { adapter.features } }
      threads.each(&:join)
    end

    it 'does not lose concurrent writes to different features' do
      keys = %w[alpha beta gamma delta]

      threads = keys.map do |key|
        Thread.new do
          flipper[key].enable
        rescue Flipper::Adapters::FirebaseRemoteConfig::ETagMismatch
          retry
        end
      end
      threads.each(&:join)

      adapter.reload!
      expect(adapter.features).to include(*keys)
    end
  end

  describe '#swap_cache' do
    let(:adapter) { described_class.new(client: client, cache_ttl: 60) }

    it 'installs a template without a round-trip' do
      feature.enable
      template, etag = client.fetch_template

      adapter.reload!
      adapter.swap_cache(template, etag)

      expect(client).not_to receive(:fetch_template)
      expect(adapter.features).to include('search')
    end
  end
end
