module Flipper
  module Adapters
    class FirebaseRemoteConfig
      # How a feature's gates map to a Remote Config parameter, and back.
      #
      # Split out of the adapter because that class sits against RuboCop's
      # 250-line ClassLength cap, but the seam is a real one: everything here
      # is about the *stored shape* — which parameters are ours, how a gate
      # hash becomes a value, and how a value reads back as gates. The adapter
      # proper is Flipper's interface plus the cache and ETag machinery.
      #
      # The shape is a public interface. Client apps read these parameters, so
      # a change here is a breaking change for every app — see the storage
      # notes in CLAUDE.md before touching it.
      module GateStorage
        private

        def flipper_feature?(param)
          return true if param['valueType'] == 'BOOLEAN'

          raw = param.dig('defaultValue', 'value')
          return false if raw.nil?

          parsed = begin
            JSON.parse(raw)
          rescue JSON::ParserError
            nil
          end
          return true if [true, false].include?(parsed)

          # Every blob we write starts from default_config, so it always carries
          # all five keys. Requiring the complete set costs nothing and keeps an
          # app's own JSON config out — `{"groups": [...]}` is an ordinary thing
          # to find in a mobile app's parameters, and matching on any single key
          # would claim it as a feature.
          parsed.is_a?(Hash) && (GATE_KEYS - parsed.keys).empty?
        end

        def ensure_parameter(template, feature_key)
          return if (template['parameters'] || {}).key?(feature_key)

          write_gates(template, feature_key, default_config)
        end

        def read_gates(template, feature_key)
          param = (template['parameters'] || {})[feature_key]
          raw   = param&.dig('defaultValue', 'value')
          return default_config if raw.nil?

          # A BOOLEAN parameter may have been typed by hand in the console, so
          # accept everything Firebase accepts rather than only "true"/"false".
          return boolean_gates(raw) if param['valueType'] == 'BOOLEAN'

          parse_gates(raw)
        end

        def parse_gates(raw)
          case (parsed = JSON.parse(raw, symbolize_names: true))
          when Hash        then deserialize_gates(parsed)
          when true, false then boolean_gates(parsed.to_s)
          else default_config
          end
        rescue JSON::ParserError
          default_config
        end

        # `false` round-trips to boolean: nil, not "false" — #disable writes an
        # all-nil config, and Flipper's shared adapter spec compares #get against
        # default_config exactly.
        def boolean_gates(raw)
          return default_config unless TRUTHY.include?(raw.to_s.downcase)

          default_config.merge(boolean: 'true')
        end

        # Simple features become real BOOLEAN parameters so a client can call
        # getBoolean() on them. Anything using actor, group or percentage gates
        # falls back to the JSON blob, which only the backend can interpret.
        def write_gates(template, feature_key, gates)
          if boolean_only?(gates)
            # Typecast, don't test truthiness: the value is the *string* "true" or
            # "false", and "false" is truthy in Ruby. Flipper reads this same value
            # through Typecast.to_boolean, so anything else here means the write
            # path and Flipper's read path disagree about what is stored.
            write_parameter(template, feature_key,
                            ::Flipper::Typecast.to_boolean(gates[:boolean]) ? 'true' : 'false',
                            type: 'BOOLEAN')
          else
            warn_client_visibility_loss(template, feature_key)
            write_parameter(template, feature_key,
                            JSON.generate(serialize_gates(gates)), type: 'JSON')
          end
        end

        # Note percentages are compared as blank, not nil: Flipper's
        # #disable_percentage_of_actors stores the string "0" rather than clearing
        # the gate, and "0" means the same thing as absent. Testing .nil? here
        # pushed an otherwise boolean-only feature into the JSON blob, which turns
        # it off for every client while the backend still reports it enabled.
        def boolean_only?(gates)
          Array(gates[:actors]).empty? &&
            Array(gates[:groups]).empty? &&
            blank_percentage?(gates[:percentage_of_actors]) &&
            blank_percentage?(gates[:percentage_of_time])
        end

        def blank_percentage?(value)
          value.nil? || value.to_i.zero?
        end

        # getBoolean() on a JSON blob returns false rather than erroring, so a
        # feature that gains an actor gate silently switches off for every client.
        # At least make the moment it happens visible.
        def warn_client_visibility_loss(template, feature_key)
          param = (template['parameters'] || {})[feature_key]
          return unless param && param['valueType'] == 'BOOLEAN'

          warn "flipper-firebase_remote_config: feature #{feature_key.inspect} is no " \
               'longer a plain boolean, so Firebase clients reading it will now see ' \
               'false. Keep client-visible features boolean-only.'
        end

        # Merge rather than replace. A console-authored parameter is a first-class
        # feature now, so it can carry fields we don't own — a description, or
        # conditionalValues driving a rollout — and a wholesale replace would drop
        # them without a word.
        def write_parameter(template, name, value, type: 'JSON')
          template['parameters'] ||= {}
          existing = template['parameters'][name] || {}
          template['parameters'][name] = preserved_fields(existing, name, type).merge(
            'valueType' => type,
            'defaultValue' => { 'value' => value }
          )
        end

        # conditionalValues hold values of the parameter's own type, so carrying
        # them across a type change would leave the template inconsistent (and the
        # API may reject it). Drop them in that one case, loudly.
        def preserved_fields(existing, name, type)
          return existing if existing.empty? || existing['valueType'] == type
          return existing unless existing.key?('conditionalValues')

          warn "flipper-firebase_remote_config: feature #{name.inspect} changed from " \
               "#{existing['valueType']} to #{type}, so its conditionalValues were " \
               'dropped — any Remote Config rollout on it no longer applies.'
          existing.reject { |key, _| key == 'conditionalValues' }
        end

        def serialize_gates(gates)
          gates.each_with_object({}) do |(key, value), acc|
            acc[key] = value.is_a?(Set) ? value.to_a : value
          end
        end

        def deserialize_gates(raw)
          default_config.merge(
            boolean: raw[:boolean],
            actors: Set.new(Array(raw[:actors])),
            groups: Set.new(Array(raw[:groups])),
            percentage_of_actors: raw[:percentage_of_actors],
            percentage_of_time: raw[:percentage_of_time]
          )
        end
      end
    end
  end
end
