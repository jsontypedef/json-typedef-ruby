require 'time'

module JTD
  def self.validate(schema, instance, options = ValidationOptions.new)
    state = ValidationState.new
    state.options = options
    state.root_schema = schema
    state.instance_tokens = []
    state.schema_tokens = [[]]
    state.errors = []

    begin
      validate_with_state(state, schema, instance)
    rescue MaxErrorsReachedError
      # This is just a dummy error to immediately stop validation. We swallow
      # the error here, and return the abridged set of errors.
    end

    state.errors
  end

  class ValidationOptions
    attr_accessor :max_depth, :max_errors

    def initialize(max_depth: 0, max_errors: 0)
      @max_depth = max_depth
      @max_errors = max_errors
    end
  end

  class ValidationError < Struct.new(:instance_path, :schema_path)
    def self.from_hash(hash)
      instance_path = hash['instancePath']
      schema_path = hash['schemaPath']

      ValidationError.new(instance_path, schema_path)
    end
  end

  class MaxDepthExceededError < StandardError
    def initialize(msg = 'max depth exceeded during JTD::validate')
      super
    end
  end

  private

  class ValidationState
    attr_accessor :options, :root_schema, :instance_tokens, :schema_tokens, :errors

    def push_instance_token(token)
      instance_tokens << token
    end

    def pop_instance_token
      instance_tokens.pop
    end

    def push_schema_token(token)
      schema_tokens.last << token
    end

    def pop_schema_token
      schema_tokens.last.pop
    end

    def push_error
      errors << ValidationError.new(instance_tokens.clone, schema_tokens.last.clone)

      raise MaxErrorsReachedError.new if errors.size == options.max_errors
    end
  end

  private_constant :ValidationState

  class MaxErrorsReachedError < StandardError
  end

  private_constant :MaxErrorsReachedError

  def self.validate_with_state(state, schema, instance, parent_tag = nil)
    return if schema.nullable && instance.nil?

    case schema.form
    when :ref
      state.schema_tokens << ['definitions', schema.ref]
      p state.schema_tokens.length, state.options, state.options.max_depth
      raise MaxDepthExceededError.new if state.schema_tokens.length == state.options.max_depth

      validate_with_state(state, state.root_schema.definitions[schema.ref], instance)
      state.schema_tokens.pop

    when :type
      state.push_schema_token('type')

      case schema.type
      when 'boolean'
        state.push_error unless instance == true || instance == false
      when 'float32', 'float64'
        state.push_error unless instance.is_a?(Numeric)
      when 'int8'
        validate_int(state, instance, -128, 127)
      when 'uint8'
        validate_int(state, instance, 0, 255)
      when 'int16'
        validate_int(state, instance, -32_768, 32_767)
      when 'uint16'
        validate_int(state, instance, 0, 65_535)
      when 'int32'
        validate_int(state, instance, -2_147_483_648, 2_147_483_647)
      when 'uint32'
        validate_int(state, instance, 0, 4_294_967_295)
      when 'string'
        state.push_error unless instance.is_a?(String)
      when 'timestamp'
        begin
          DateTime.rfc3339(instance)
        rescue TypeError, ArgumentError
          state.push_error
        end
      end

      state.pop_schema_token

    when :enum
      state.push_schema_token('enum')
      state.push_error unless schema.enum.include?(instance)
      state.pop_schema_token

    when :elements
      state.push_schema_token('elements')

      if instance.is_a?(Array)
        instance.each_with_index do |sub_instance, index|
          state.push_instance_token(index.to_s)
          validate_with_state(state, schema.elements, sub_instance)
          state.pop_instance_token
        end
      else
        state.push_error
      end

      state.pop_schema_token

    when :properties
      # The properties form is a little weird. The JSON Typedef spec always
      # works out so that the schema path points to a part of the schema that
      # really exists, and there's no guarantee that a schema of the properties
      # form has the properties keyword.
      #
      # To deal with this, we handle the "instance isn't even an object" case
      # separately.
      unless instance.is_a?(Hash)
        if schema.properties
          state.push_schema_token('properties')
        else
          state.push_schema_token('optionalProperties')
        end

        state.push_error
        state.pop_schema_token

        return
      end

      # Check the required properties.
      if schema.properties
        state.push_schema_token('properties')

        schema.properties.each do |property, sub_schema|
          state.push_schema_token(property)

          if instance.key?(property)
            state.push_instance_token(property)
            validate_with_state(state, sub_schema, instance[property])
            state.pop_instance_token
          else
            state.push_error
          end

          state.pop_schema_token
        end

        state.pop_schema_token
      end

      # Check the optional properties. This is almost identical to the previous
      # case, except we don't raise an error if the property isn't present on
      # the instance.
      if schema.optional_properties
        state.push_schema_token('optionalProperties')

        schema.optional_properties.each do |property, sub_schema|
          state.push_schema_token(property)

          if instance.key?(property)
            state.push_instance_token(property)
            validate_with_state(state, sub_schema, instance[property])
            state.pop_instance_token
          end

          state.pop_schema_token
        end

        state.pop_schema_token
      end

      # Check for unallowed additional properties.
      unless schema.additional_properties
        properties = (schema.properties || {}).keys
        optional_properties = (schema.optional_properties || {}).keys
        parent_tags = [parent_tag]

        additional_keys = instance.keys - properties - optional_properties - parent_tags
        additional_keys.each do |property|
          state.push_instance_token(property)
          state.push_error
          state.pop_instance_token
        end
      end

    when :values
      state.push_schema_token('values')

      if instance.is_a?(Hash)
        instance.each do |property, sub_instance|
          state.push_instance_token(property)
          validate_with_state(state, schema.values, sub_instance)
          state.pop_instance_token
        end
      else
        state.push_error
      end

      state.pop_schema_token

    when :discriminator
      unless instance.is_a?(Hash)
        state.push_schema_token('discriminator')
        state.push_error
        state.pop_schema_token

        return
      end

      unless instance.key?(schema.discriminator)
        state.push_schema_token('discriminator')
        state.push_error
        state.pop_schema_token

        return
      end

      unless instance[schema.discriminator].is_a?(String)
        state.push_schema_token('discriminator')
        state.push_instance_token(schema.discriminator)
        state.push_error
        state.pop_instance_token
        state.pop_schema_token

        return
      end

      unless schema.mapping.key?(instance[schema.discriminator])
        state.push_schema_token('mapping')
        state.push_instance_token(schema.discriminator)
        state.push_error
        state.pop_instance_token
        state.pop_schema_token

        return
      end

      sub_schema = schema.mapping[instance[schema.discriminator]]

      state.push_schema_token('mapping')
      state.push_schema_token(instance[schema.discriminator])
      validate_with_state(state, sub_schema, instance, schema.discriminator)
      state.pop_schema_token
      state.pop_schema_token
    end
  end

  def self.validate_int(state, instance, min, max)
    if instance.is_a?(Numeric)
      if instance.modulo(1).nonzero? || instance < min || instance > max
        state.push_error
      end
    else
      state.push_error
    end
  end
end
