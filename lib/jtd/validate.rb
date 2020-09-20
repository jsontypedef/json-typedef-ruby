require 'time'

module JTD
  # Validates +instance+ against +schema+ according to the JSON Type Definition
  # specification.
  #
  # Returns a list of ValidationError. If there are no validation errors, then
  # the returned list will be empty.
  #
  # By default, all errors are returned, and an unlimited number of references
  # will be followed. If you are running #validate against schemas that may
  # return a lot of errors, or which may contain circular references, then this
  # can cause performance issues or stack overflows.
  #
  # To mitigate this risk, consider using +options+, which must be an instance
  # of ValidationOptions, to limit the number of errors returned or references
  # followed.
  #
  # If ValidationOptions#max_depth is reached, then #validate will raise a
  # MaxDepthExceededError.
  #
  # The return value of #validate is not well-defined if the schema is not
  # valid, i.e. Schema#verify raises an error.
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

  # Options you can pass to JTD::validate.
  class ValidationOptions
    # The maximum number of references to follow before aborting validation. You
    # can use this to prevent a stack overflow when validating schemas that
    # potentially have infinite loops, such as this one:
    #
    #   {
    #     "definitions": {
    #       "loop": { "ref": "loop" }
    #     },
    #     "ref": "loop"
    #   }
    #
    # The default value for +max_depth+ is 0, which indicates that no max depth
    # should be imposed at all.
    attr_accessor :max_depth

    # The maximum number of errors to return. You can use this to have
    # JTD::validate have better performance if you don't have any use for errors
    # beyond a certain count.
    #
    # For instance, if all you care about is whether or not there are any
    # validation errors at all, you can set +max_errors+ to 1. If you're
    # presenting validation errors in an interface that can't show more than 5
    # errors, set +max_errors+ to 5.
    #
    # The default value for +max_errors+ is 0, which indicates that all errors
    # will be returned.
    attr_accessor :max_errors

    # Construct a new set of ValidationOptions with the given +max_depth+ and
    # +max_errors+.
    #
    # See the documentation for +max_depth+ and +max_errors+ for what their
    # default values of 0 mean.
    def initialize(max_depth: 0, max_errors: 0)
      @max_depth = max_depth
      @max_errors = max_errors
    end
  end

  # Represents a single JSON Type Definition validation error.
  #
  # ValidationError does not extend StandardError; it is not a Ruby exception.
  # It is a plain old Ruby object.
  #
  # Every ValidationError has two attributes:
  #
  # * +instance_path+ is an array of strings. It represents the path to the part
  #   of the +instance+ passed to JTD::validate that was rejected.
  #
  # * +schema_path+ is an array of strings. It represents the path to the part
  #   of the +schema+ passed to JTD::validate that rejected the instance at
  #   +instance_path+.
  class ValidationError < Struct.new(:instance_path, :schema_path)

    # Constructs a new ValidationError from the standard JSON representation of
    # a validation error in JSON Type Definition.
    def self.from_hash(hash)
      instance_path = hash['instancePath']
      schema_path = hash['schemaPath']

      ValidationError.new(instance_path, schema_path)
    end
  end

  # Error raised from JTD::validate if the number of references followed exceeds
  # ValidationOptions#max_depth.
  class MaxDepthExceededError < StandardError
    # Constructs a new MaxDepthExceededError.
    def initialize(msg = 'max depth exceeded during JTD::validate')
      super
    end
  end

  private

  class ValidationState # :nodoc:
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

  class MaxErrorsReachedError < StandardError # :nodoc:
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
