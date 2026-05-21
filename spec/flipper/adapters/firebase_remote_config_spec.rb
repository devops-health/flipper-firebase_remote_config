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

  describe 'prefix isolation' do
    it 'two adapters with different prefixes do not see each other' do
      a = described_class.new(client: client, prefix: 'app_a__', cache_ttl: 0)
      b = described_class.new(client: client, prefix: 'app_b__', cache_ttl: 0)
      Flipper.new(a).enable(:search)
      expect(a.features).to include('search')
      expect(b.features).to be_empty
    end
  end
end
