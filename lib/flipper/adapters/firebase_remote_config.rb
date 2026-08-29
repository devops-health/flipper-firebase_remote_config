require 'json'
require 'monitor'
require 'set'
require 'flipper'
require 'flipper/adapters/firebase_remote_config/version'
require 'flipper/adapters/firebase_remote_config/client'
require 'flipper/adapters/firebase_remote_config/gate_storage'
require 'flipper/adapters/firebase_remote_config/listener'

module Flipper
  module Adapters
    # Flipper adapter that stores feature state as Firebase Remote Config
    # parameters. One parameter per feature, named for the feature key exactly,
    # because client apps read these names too.
    #
    # A simple on/off feature is a real BOOLEAN parameter, so a Firebase client
    # can call getBoolean() on it. A feature using actor, group or percentage
    # gates falls back to a JSON blob only the backend can interpret.
    #
    # The in-memory representation of a template is the raw API JSON shape:
    #
    #   {
    #     "parameters" => {
    #       "search" => {
    #         "valueType" => "BOOLEAN",
    #         "defaultValue" => { "value" => "true" }
    #       },
    #       "beta_ui" => {
    #         "valueType" => "JSON",
    #         "defaultValue" => { "value" => "{\"actors\":[\"1\"],...}" }
    #       }
    #     },
    #     "conditions" => [...],
    #     ...
    #   }
    #
    # See README.md for the rationale and for caveats (eventual consistency,
    # write quotas, no support for Remote Config conditions in v0.1).
    class FirebaseRemoteConfig
      include GateStorage

      DEFAULT_CACHE_TTL = 30 # seconds

      # The gate keys we persist. Also how we recognise one of our parameters
      # among the app's own — see #flipper_feature?.
      GATE_KEYS = %w[
        boolean actors groups percentage_of_actors percentage_of_time
      ].freeze

      # Strings Firebase treats as a true BOOLEAN parameter value.
      TRUTHY = %w[true 1 t yes y on].freeze

      attr_reader :name

      def initialize(project_id: nil, credentials: nil, client: nil,
                     cache_ttl: DEFAULT_CACHE_TTL)
        @name      = :firebase_remote_config
        @cache_ttl = cache_ttl
        @client    = client || Client.new(project_id: project_id, credentials: credentials)
        @cache     = nil
        @cached_at = nil
        # Reentrant on purpose: with_template's snapshot re-enters load_template.
        @monitor   = Monitor.new
      end

      def features
        Set.new(feature_keys(load_template))
      end

      def add(feature)
        with_template { |template| ensure_parameter(template, feature.key) }
        true
      end

      def remove(feature)
        with_template { |template| template['parameters']&.delete(feature.key) }
        true
      end

      def clear(feature)
        with_template do |template|
          write_gates(template, feature.key, default_config)
        end
        true
      end

      def get(feature)
        read_gates(load_template, feature.key)
      end

      def get_multi(features)
        template = load_template
        features.to_h do |feature|
          [feature.key, read_gates(template, feature.key)]
        end
      end

      def get_all
        template = load_template
        feature_keys(template).to_h do |feature_key|
          [feature_key, read_gates(template, feature_key)]
        end
      end

      def enable(feature, gate, thing)
        ensure_persistable_gate!(gate)
        mutate_gates(feature) { |gates| apply_enable_gate(gates, gate, thing) }
        true
      end

      def disable(feature, gate, thing)
        ensure_persistable_gate!(gate)
        mutate_gates(feature) { |gates| apply_disable_gate(gates, gate, thing) }
        true
      end

      # Drop the in-process cache. Call this when you know the template has
      # drifted (e.g. another process published a new version).
      def reload!
        @monitor.synchronize do
          @cache = nil
          @cached_at = nil
        end
        self
      end

      # The version number of the latest published template, or nil. Cheap
      # enough to poll — it doesn't pull the template.
      def latest_version
        @client.latest_version
      end

      # Fetch the current template, install it, and return it. This is what a
      # Listener calls once its probe says the version moved.
      #
      # The fetch happens outside the monitor, so a listener fetch that started
      # before a local write can install the older template over the newer one.
      # It self-heals — the next probe sees the version moved, and a write racing
      # it hits a 412 and retries — and the window is smaller than the cache_ttl
      # staleness this adapter already accepts. Holding the monitor across the
      # GET instead would block every reader for the length of a fetch.
      def refresh!
        template, etag = @client.fetch_template
        swap_cache(template, etag)
        template
      end

      # Which parameters in a template are features of ours. Public because a
      # Listener needs it to diff two templates without duplicating the rule.
      def feature_keys(template)
        (template['parameters'] || {}).each_with_object([]) do |(key, param), acc|
          acc << key if flipper_feature?(param)
        end.sort
      end

      # Install a template that is already known to be current, without paying
      # for a round-trip. Used by out-of-band change detection.
      def swap_cache(template, etag)
        @monitor.synchronize do
          @cache     = { template: template, etag: etag }
          @cached_at = Time.now
        end
        self
      end

      private

      def mutate_gates(feature)
        with_template do |template|
          gates = yield(read_gates(template, feature.key))
          write_gates(template, feature.key, gates)
        end
      end

      def apply_enable_gate(gates, gate, thing)
        case gate.data_type
        when :boolean
          default_config.merge(gate.key => thing.value.to_s)
        when :integer
          gates.merge(gate.key => thing.value.to_s)
        when :set
          gates.merge(gate.key => (gates[gate.key] || Set.new) | [thing.value.to_s])
        when :json
          gates.merge(gate.key => thing.value)
        else
          raise ArgumentError, "Unsupported gate data_type: #{gate.data_type.inspect}"
        end
      end

      def apply_disable_gate(gates, gate, thing)
        case gate.data_type
        when :boolean
          default_config
        when :integer
          gates.merge(gate.key => thing.value.to_s)
        when :set
          gates.merge(gate.key => (gates[gate.key] || Set.new) - [thing.value.to_s])
        when :json
          gates.merge(gate.key => nil)
        else
          raise ArgumentError, "Unsupported gate data_type: #{gate.data_type.inspect}"
        end
      end

      # Fail closed on a gate outside the five we persist. Flipper's :expression
      # gate reaches the :json branch below and would otherwise pass
      # boolean_only? — which inspects only the four non-boolean gates it knows —
      # and be written as a plain BOOLEAN, discarding the gate silently.
      def ensure_persistable_gate!(gate)
        return if GATE_KEYS.include?(gate.key.to_s)

        raise ArgumentError,
              "Unsupported gate #{gate.key.inspect}. This adapter persists only " \
              "#{GATE_KEYS.join(', ')} — see \"Adding a new gate type\" in CLAUDE.md."
      end

      def default_config
        {
          boolean: nil,
          actors: Set.new,
          groups: Set.new,
          percentage_of_actors: nil,
          percentage_of_time: nil
        }
      end

      # The returned template is shared between threads and MUST be treated as
      # read-only. Writers go through checkout_template for a private copy.
      #
      # The fetch happens while holding the monitor, so concurrent callers on a
      # cold cache wait for one GET rather than each issuing their own.
      def load_template
        @monitor.synchronize do
          if @cache && @cached_at && (Time.now - @cached_at) < @cache_ttl
            @cache[:template]
          else
            template, etag = @client.fetch_template
            @cache     = { template: template, etag: etag }
            @cached_at = Time.now
            template
          end
        end
      end

      # Returns [private_template_copy, etag] captured atomically, so the etag
      # always belongs to the template it came with.
      def checkout_template
        @monitor.synchronize do
          template = load_template
          [deep_copy(template), @cache[:etag]]
        end
      end

      # The template is the raw API JSON shape, so a JSON round-trip is a
      # sufficient deep copy and costs us no dependency.
      def deep_copy(template)
        JSON.parse(JSON.generate(template))
      end

      # Mutate a private copy of the template inside the block, then publish it.
      # Retries once on ETag mismatch by reloading and reapplying the block.
      #
      # The copy is what makes concurrent reads safe: readers keep seeing the
      # cached template untouched until the write lands. Two writers racing is
      # resolved by the ETag, not by a lock, so no lock is held across the PUT.
      def with_template
        attempts = 0
        begin
          template, etag = checkout_template
          before = JSON.generate(template)
          yield template
          # Flipper's Feature#enable calls add then enable, and add changes
          # nothing for a feature that already exists. Publishing that anyway
          # spent a write against a quota measured in hundreds per day.
          return if JSON.generate(template) == before

          @client.publish_template(template, etag)
          reload!
        rescue FirebaseRemoteConfig::ETagMismatch
          attempts += 1
          if attempts <= 1
            reload!
            retry
          end
          raise
        end
      end

      # A feature is a parameter we recognise as ours. There is no prefix and no
      # index sentinel: parameter names are the feature keys verbatim, because
      # client apps read these names and `flipper__search` leaked an
      # implementation detail into an interface they see.
      #
      # The trade: an app's own BOOLEAN parameter shows up as a feature. For an
      # adapter whose whole point is that both sides read the same parameters,
      # that is closer to right than wrong — and it means a flag created in the
      # Firebase console is a real feature here, which the index made impossible.
    end
  end
end
