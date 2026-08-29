RSpec.describe Flipper::Adapters::FirebaseRemoteConfig::Listener do
  subject(:listener) { described_class.new(adapter, interval: 1) }

  let(:client)  { FakeClient.new }
  let(:adapter) { Flipper::Adapters::FirebaseRemoteConfig.new(client: client, cache_ttl: 60) }
  let(:flipper) { Flipper.new(adapter) }

  # Publish a change the way another process or the Firebase console would,
  # behind the adapter's back.
  def publish_externally
    template, etag = client.fetch_template
    yield template
    client.publish_template(template, etag)
  end

  def boolean_param(value)
    { 'valueType' => 'BOOLEAN', 'defaultValue' => { 'value' => value } }
  end

  describe '#tick' do
    it 'does nothing while the version is unchanged' do
      listener.tick
      expect(client).not_to receive(:fetch_template)
      expect(listener.tick).to be(false)
    end

    it 'refreshes once the version moves' do
      listener.tick
      publish_externally { |t| t['parameters']['search'] = boolean_param('true') }

      expect(listener.tick).to be(true)
      expect(adapter.features).to include('search')
    end

    it 'reports nothing on the first tick' do
      flipper[:search].enable
      changed = :never_called
      listener.on_change { |keys| changed = keys }

      listener.tick

      expect(changed).to eq(:never_called)
    end

    it 'reports only the features that actually changed' do
      flipper[:search].enable
      flipper[:beta].enable
      listener.tick

      publish_externally { |t| t['parameters']['search'] = boolean_param('false') }

      changed = nil
      listener.on_change { |keys| changed = keys }
      listener.tick

      expect(changed).to eq(['search'])
    end

    it 'reports an added feature' do
      listener.tick
      publish_externally { |t| t['parameters']['added'] = boolean_param('true') }

      changed = nil
      listener.on_change { |keys| changed = keys }
      listener.tick

      expect(changed).to eq(['added'])
    end

    it 'reports a removed feature' do
      flipper[:search].enable
      listener.tick

      publish_externally { |t| t['parameters'].delete('search') }

      changed = nil
      listener.on_change { |keys| changed = keys }
      listener.tick

      expect(changed).to eq(['search'])
    end

    it 'ignores parameters that are not features' do
      listener.tick
      publish_externally do |t|
        t['parameters']['welcome_message'] =
          { 'valueType' => 'STRING', 'defaultValue' => { 'value' => 'Hi' } }
      end

      changed = nil
      listener.on_change { |keys| changed = keys }
      listener.tick

      expect(changed).to be_nil
    end

    it 'keeps calling handlers after one of them raises' do
      listener.tick
      publish_externally { |t| t['parameters']['search'] = boolean_param('true') }

      seen = []
      listener.on_change { |_| raise 'boom' }
      listener.on_change { |keys| seen = keys }

      expect { listener.tick }.to output(/boom/).to_stderr
      expect(seen).to eq(['search'])
    end
  end

  describe 'the probe seam' do
    it 'uses a callable probe instead of asking the adapter' do
      probe = -> { 42 }
      listener = described_class.new(adapter, probe: probe)

      expect(adapter).not_to receive(:latest_version)
      listener.tick
      expect(listener.last_version).to eq(42)
    end

    it 'uses an object that responds to current_version' do
      probe = Struct.new(:current_version).new(7)
      listener = described_class.new(adapter, probe: probe)

      listener.tick

      expect(listener.last_version).to eq(7)
    end

    it 'refreshes every tick when the probe has no version to report' do
      listener = described_class.new(adapter, probe: -> {})

      expect(client).to receive(:fetch_template).twice.and_call_original
      2.times { listener.tick }
    end
  end

  describe 'recovering from a failed baseline' do
    it 'still reports the first change after prime fails' do
      boom = true
      allow(adapter).to receive(:refresh!).and_wrap_original do |original, *args|
        if boom
          boom = false
          raise Flipper::Adapters::FirebaseRemoteConfig::Error, 'blip'
        end
        original.call(*args)
      end

      # The run loop wraps prime in the same rescue, so a boot-time blip is
      # swallowed and the thread carries on.
      begin
        listener.send(:prime)
      rescue Flipper::Adapters::FirebaseRemoteConfig::Error
        nil
      end

      listener.tick # recovery: establishes the baseline prime couldn't

      publish_externally { |t| t['parameters']['beta'] = boolean_param('true') }

      changed = :never_called
      listener.on_change { |keys| changed = keys }
      listener.tick

      expect(changed).to eq(['beta'])
    end
  end

  describe 'the polling thread' do
    after { listener.stop }

    it 'starts and reports itself running' do
      listener.start
      expect(listener.running?).to be(true)
    end

    it 'is idempotent' do
      listener.start
      thread_count = Thread.list.size
      listener.start
      expect(Thread.list.size).to eq(thread_count)
    end

    it 'stops promptly rather than waiting out the interval' do
      slow = described_class.new(adapter, interval: 3600)
      slow.start

      elapsed = Time.now
      slow.stop

      expect(Time.now - elapsed).to be < 1
      expect(slow.running?).to be(false)
    end

    it 'survives a probe that raises' do
      allow(adapter).to receive(:latest_version).and_raise(
        Flipper::Adapters::FirebaseRemoteConfig::Error, 'boom'
      )

      expect { listener.tick }.to raise_error(
        Flipper::Adapters::FirebaseRemoteConfig::Error
      )

      listener.start
      expect(listener.running?).to be(true)
    end

    it 'stop is safe to call without start' do
      expect { listener.stop }.not_to raise_error
    end

    it 'does not spawn a second poller when a tick outlives stop' do
      stub_const("#{described_class}::STOP_JOIN_TIMEOUT", 0.05)
      release = Queue.new
      allow(adapter).to receive(:refresh!) { release.pop }

      listener.start
      sleep 0.05 until listener.instance_variable_get(:@ticking).locked?

      expect { listener.stop }.to output(/still running/).to_stderr

      threads_before = Thread.list.size
      listener.start
      expect(Thread.list.size).to eq(threads_before)

      # And it must still be polling. Returning early from #start without
      # re-arming @running left the outgoing thread to exit at its next check,
      # so the listener reported success and then polled nothing.
      release << { 'parameters' => {} } # let the wedged tick finish
      sleep 0.1
      expect(listener.running?).to be(true)
    end
  end

  describe 'concurrent ticks' do
    # Deliberately holds the first tick inside refresh! so the others have to
    # overlap it. Without the lock they all sail past the version check together
    # and four fetches land; simply racing four threads isn't enough to prove
    # anything, because the first one usually finishes before the rest look.
    it 'serializes so a caller never sees a version from one fetch and a template from another' do
      entered = Queue.new
      release = Queue.new
      allow(adapter).to receive(:refresh!) do
        entered << :in
        release.pop
        { 'parameters' => {} }
      end

      threads = Array.new(4) { Thread.new { listener.tick } }
      sleep 0.1 # let every thread reach either refresh! or the lock

      expect(entered.size).to eq(1)

      4.times { release << :go }
      threads.each(&:join)
    end
  end
end
