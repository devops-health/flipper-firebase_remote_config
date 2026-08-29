require 'monitor'

module Flipper
  module Adapters
    class FirebaseRemoteConfig
      # Watches Remote Config for template changes and keeps the adapter's cache
      # current, so a flag published in the Firebase console reaches a running
      # process in seconds rather than whenever `cache_ttl` happens to lapse.
      #
      # Each tick asks a *probe* for the current template version. That is a
      # cheap `listVersions` call, not a template fetch, so polling it often is
      # affordable. Only when the version actually moves does the listener pull
      # the template, install it, and report which features changed.
      #
      #   listener = Flipper::Adapters::FirebaseRemoteConfig::Listener.new(adapter)
      #   listener.on_change do |keys|
      #     keys.each { |key| cache.expire_feature_cache(key) }
      #     cache.expire_get_all_cache
      #   end
      #   listener.start
      #
      # The adapter's own cache is refreshed with no callback required.
      # `on_change` is for cache stores sitting *in front* of the adapter, which
      # the listener has no way to reach on its own.
      #
      # Threads do not survive `fork`, so never start a listener before one — in
      # clustered Puma use `on_worker_boot`, in Sidekiq use `config.on(:startup)`.
      # A pid change is detected and the thread respawned, but that is a
      # backstop, not a substitute for wiring it up correctly.
      class Listener
        DEFAULT_INTERVAL = 10
        MINIMUM_INTERVAL = 1
        MAXIMUM_BACKOFF  = 300
        # How long #stop waits for the thread to finish its current tick. A tick
        # can legitimately take ~20s (the client's open + read timeouts), so this
        # expiring doesn't mean the thread is wedged.
        STOP_JOIN_TIMEOUT = 5
        # Fraction of the interval to jitter by, so N processes don't all wake
        # on the same second and stampede the API.
        JITTER = 0.3

        attr_reader :interval, :last_version

        # probe - anything answering #current_version, or any callable. Defaults
        #         to the adapter's own listVersions call. This is the seam for
        #         push-based sources: a webhook writing the version into a shared
        #         cache, or the realtime stream.
        def initialize(adapter, interval: DEFAULT_INTERVAL, probe: nil, logger: nil, &block)
          @adapter  = adapter
          @interval = [interval.to_f, MINIMUM_INTERVAL].max
          @probe    = probe
          @logger   = logger
          @handlers = []
          @handlers << block if block

          @monitor  = Monitor.new
          @wake     = @monitor.new_cond
          # Separate from @monitor on purpose: a tick holds this across network
          # I/O, and #stop must not queue behind it.
          @ticking  = Mutex.new
          @running  = false
          @thread   = nil
          @pid      = nil
          @failures = 0
          @last_version  = nil
          @last_template = nil
        end

        def on_change(&block)
          @handlers << block
          self
        end

        def start
          @monitor.synchronize do
            return self if alive?

            @running = true
            @pid     = Process.pid
            @thread  = Thread.new { run }
            @thread.report_on_exception = false
          end
          self
        end

        # Returns once the thread has actually stopped. Prompt: the poll waits on
        # a condition variable rather than sleeping, so this doesn't block for
        # the remainder of an interval.
        def stop
          thread = @monitor.synchronize do
            @running = false
            @wake.broadcast
            @thread
          end
          thread&.join(STOP_JOIN_TIMEOUT)

          # Only forget the thread once it's actually gone. Clearing it while it
          # still runs would make #alive? false, and the next #start would spawn
          # a second poller alongside the first.
          if thread&.alive?
            report(RuntimeError.new("listener thread still running after #{STOP_JOIN_TIMEOUT}s"))
          else
            @monitor.synchronize { @thread = nil }
          end
          self
        end

        def running?
          @monitor.synchronize { @running && alive? }
        end

        # One poll, run inline. Public so specs can drive the loop without
        # waiting on wall-clock time, and so a caller can force one by hand.
        #
        # Serialized on its own lock, not @monitor: a tick holds it across
        # network I/O, and #stop must stay prompt. Racing the poll thread means
        # waiting rather than interleaving with it, which would otherwise leave
        # a version from one fetch beside a template from another.
        #
        # Returns true if the template was refreshed, false if the version was
        # unchanged and nothing was done.
        def tick
          @ticking.synchronize do
            version = current_version
            next false if version && version == @last_version

            template = @adapter.refresh!
            changed  = @last_template ? changed_keys(@last_template, template) : []
            @last_version  = version
            @last_template = template
            notify(changed) if changed.any?
            true
          end
        end

        private

        def alive?
          @pid == Process.pid && @thread&.alive?
        end

        def run
          # The first tick establishes a baseline. Without it every feature would
          # look new and the first poll would fire a change for all of them.
          guarded { prime }

          loop do
            break unless wait_for_next_tick

            guarded { tick }
          end
        end

        # Same critical section as #tick — it touches the same state, and a
        # caller can hand-drive #tick before start's baseline has finished.
        def prime
          @ticking.synchronize do
            @last_version  = current_version
            @last_template = @adapter.refresh!
          end
        end

        # An exception must never kill the thread — a Remote Config blip would
        # otherwise silently end change detection for the life of the process.
        def guarded
          yield
          @failures = 0
        rescue StandardError => e
          @failures += 1
          report(e)
        end

        def wait_for_next_tick
          @monitor.synchronize do
            return false unless @running

            @wake.wait(next_delay)
            @running
          end
        end

        def next_delay
          base = if @failures.zero?
                   @interval
                 else
                   [@interval * (2**@failures), MAXIMUM_BACKOFF].min
                 end
          base * (1 + (((rand * 2) - 1) * JITTER))
        end

        def current_version
          return @adapter.latest_version if @probe.nil?
          return @probe.current_version if @probe.respond_to?(:current_version)

          @probe.call
        end

        # Compare the stored parameter of every feature in either template. Added
        # and removed features count as changed, so a caller expiring these keys
        # doesn't leave a deleted feature cached.
        def changed_keys(old_template, new_template)
          old_params = feature_params(old_template)
          new_params = feature_params(new_template)

          (old_params.keys | new_params.keys)
            .reject { |key| old_params[key] == new_params[key] }
            .sort
        end

        def feature_params(template)
          params = template['parameters'] || {}
          @adapter.feature_keys(template).to_h { |key| [key, params[key]] }
        end

        # One misbehaving handler shouldn't stop the others, or the thread.
        def notify(changed)
          @handlers.each do |handler|
            handler.call(changed)
          rescue StandardError => e
            report(e)
          end
        end

        def report(error)
          message = "flipper-firebase_remote_config listener: #{error.class}: #{error.message}"
          @logger ? @logger.error(message) : warn(message)
        end
      end
    end
  end
end
