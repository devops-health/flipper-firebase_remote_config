require 'json'
require 'set'
require 'flipper'
require 'flipper/adapters/firebase_remote_config/version'
require 'flipper/adapters/firebase_remote_config/client'

module Flipper
  module Adapters
    # Flipper adapter that stores feature state as Firebase Remote Config
    # parameters. One parameter per feature; an index parameter tracks the
    # known feature keys so listing doesn't have to scan the whole template.
    #
    # The in-memory representation of a template is the raw API JSON shape:
    #
    #   {
    #     "parameters" => {
    #       "flipper__search" => {
    #         "valueType" => "JSON",
    #         "defaultValue" => { "value" => "{\"boolean\":\"true\",...}" }
    #       },
    #       "flipper____index__" => { ... JSON array of feature keys ... }
    #     },
    #     "conditions" => [...],
    #     ...
    #   }
    #
    # See README.md for the rationale and for caveats (eventual consistency,
    # write quotas, no support for Remote Config conditions in v0.1).
    class FirebaseRemoteConfig
      DEFAULT_PREFIX     = 'flipper__'.freeze
      INDEX_SUFFIX       = '__index__'.freeze
      DEFAULT_CACHE_TTL  = 30 # seconds

      attr_reader :name

      def initialize(project_id: nil, credentials: nil, client: nil,
                     prefix: DEFAULT_PREFIX, cache_ttl: DEFAULT_CACHE_TTL)
        @name      = :firebase_remote_config
        @prefix    = prefix
        @cache_ttl = cache_ttl
        @client    = client || Client.new(project_id: project_id, credentials: credentials)
        @cache     = nil
        @cached_at = nil
      end

      def features
        Set.new(index_from(load_template))
      end

      def add(feature)
        with_template do |template|
          ensure_parameter(template, feature.key)
          add_to_index(template, feature.key)
        end
        true
      end

      def remove(feature)
        with_template do |template|
          template['parameters']&.delete(parameter_name(feature.key))
          remove_from_index(template, feature.key)
        end
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
        features.each_with_object({}) do |feature, acc|
          acc[feature.key] = read_gates(template, feature.key)
        end
      end

      def get_all
        template = load_template
        index_from(template).each_with_object({}) do |feature_key, acc|
          acc[feature_key] = read_gates(template, feature_key)
        end
      end

      def enable(feature, gate, thing)
        with_template do |template|
          gates = read_gates(template, feature.key)
          case gate.data_type
          when :boolean
            gates = default_config.merge(gate.key => thing.value.to_s)
          when :integer
            gates[gate.key] = thing.value.to_s
          when :set
            gates[gate.key] = (gates[gate.key] || Set.new) | [thing.value.to_s]
          when :json
            gates[gate.key] = thing.value
          else
            raise ArgumentError, "Unsupported gate data_type: #{gate.data_type.inspect}"
          end
          write_gates(template, feature.key, gates)
          add_to_index(template, feature.key)
        end
        true
      end

      def disable(feature, gate, thing)
        with_template do |template|
          gates = read_gates(template, feature.key)
          case gate.data_type
          when :boolean
            gates = default_config
          when :integer
            gates[gate.key] = thing.value.to_s
          when :set
            gates[gate.key] = (gates[gate.key] || Set.new) - [thing.value.to_s]
          when :json
            gates[gate.key] = nil
          else
            raise ArgumentError, "Unsupported gate data_type: #{gate.data_type.inspect}"
          end
          write_gates(template, feature.key, gates)
          add_to_index(template, feature.key)
        end
        true
      end

      # Drop the in-process cache. Call this when you know the template has
      # drifted (e.g. another process published a new version).
      def reload!
        @cache = nil
        @cached_at = nil
        self
      end

      private

      def default_config
        {
          boolean:              nil,
          actors:               Set.new,
          groups:               Set.new,
          percentage_of_actors: nil,
          percentage_of_time:   nil,
        }
      end

      def load_template
        if @cache && @cached_at && (Time.now - @cached_at) < @cache_ttl
          return @cache[:template]
        end

        template, etag = @client.fetch_template
        @cache     = { template: template, etag: etag }
        @cached_at = Time.now
        template
      end

      # Mutate the cached template in place inside the block, then publish it.
      # Retries once on ETag mismatch by reloading and reapplying the block.
      def with_template
        attempts = 0
        begin
          template = load_template
          etag     = @cache[:etag]
          yield template
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

      def parameter_name(feature_key)
        "#{@prefix}#{feature_key}"
      end

      def index_parameter_name
        "#{@prefix}#{INDEX_SUFFIX}"
      end

      def index_from(template)
        raw = parameter_value(template, index_parameter_name)
        return [] if raw.nil?

        JSON.parse(raw)
      rescue JSON::ParserError
        []
      end

      def add_to_index(template, feature_key)
        keys = (index_from(template) + [feature_key]).uniq.sort
        write_parameter(template, index_parameter_name, JSON.generate(keys))
      end

      def remove_from_index(template, feature_key)
        keys = index_from(template) - [feature_key]
        write_parameter(template, index_parameter_name, JSON.generate(keys))
      end

      def ensure_parameter(template, feature_key)
        return if (template['parameters'] || {}).key?(parameter_name(feature_key))

        write_gates(template, feature_key, default_config)
      end

      def read_gates(template, feature_key)
        raw_json = parameter_value(template, parameter_name(feature_key))
        return default_config if raw_json.nil?

        raw = JSON.parse(raw_json, symbolize_names: true)
        deserialize_gates(raw)
      rescue JSON::ParserError
        default_config
      end

      def write_gates(template, feature_key, gates)
        write_parameter(template, parameter_name(feature_key),
                        JSON.generate(serialize_gates(gates)))
      end

      def parameter_value(template, name)
        param = (template['parameters'] || {})[name]
        param && param.dig('defaultValue', 'value')
      end

      def write_parameter(template, name, json_value)
        template['parameters'] ||= {}
        template['parameters'][name] = {
          'valueType'    => 'JSON',
          'defaultValue' => { 'value' => json_value },
        }
      end

      def serialize_gates(gates)
        gates.each_with_object({}) do |(key, value), acc|
          acc[key] = value.is_a?(Set) ? value.to_a : value
        end
      end

      def deserialize_gates(raw)
        default_config.merge(
          boolean:              raw[:boolean],
          actors:               Set.new(Array(raw[:actors])),
          groups:               Set.new(Array(raw[:groups])),
          percentage_of_actors: raw[:percentage_of_actors],
          percentage_of_time:   raw[:percentage_of_time],
        )
      end
    end
  end
end
