module JTD
  # Represents a JSON Type Definition schema.
  class Schema
    attr_accessor *%i[
      metadata
      nullable
      definitions
      ref
      type
      enum
      elements
      properties
      optional_properties
      additional_properties
      values
      discriminator
      mapping
    ]

    # Constructs a Schema from a Hash like the kind produced by JSON#parse.
    #
    # In other words, #from_hash is meant to be used to convert some parsed JSON
    # into a Schema.
    #
    # If hash isn't a Hash or contains keys that are illegal for JSON Type
    # Definition, then #from_hash will raise a TypeError.
    #
    # If the properties of hash are not of the correct type for a JSON Type
    # Definition schema (for example, if the "elements" property of hash is
    # non-nil, but not a hash), then #from_hash may raise a NoMethodError.
    def self.from_hash(hash)
      # Raising this error early makes for a much clearer error for the
      # relatively common case of something that was expected to be an object
      # (Hash), but was something else instead.
      raise TypeError.new("expected hash, got: #{hash}") unless hash.is_a?(Hash)

      illegal_keywords = hash.keys - KEYWORDS
      unless illegal_keywords.empty?
        raise TypeError.new("illegal schema keywords: #{illegal_keywords}")
      end

      s = Schema.new

      if hash['metadata']
        s.metadata = hash['metadata']
      end

      unless hash['nullable'].nil?
        s.nullable = hash['nullable']
      end

      if hash['definitions']
        s.definitions = Hash[hash['definitions'].map { |k, v| [k, from_hash(v) ]}]
      end

      s.ref = hash['ref']
      s.type = hash['type']
      s.enum = hash['enum']

      if hash['elements']
        s.elements = from_hash(hash['elements'])
      end

      if hash['properties']
        s.properties = Hash[hash['properties'].map { |k, v| [k, from_hash(v) ]}]
      end

      if hash['optionalProperties']
        s.optional_properties = Hash[hash['optionalProperties'].map { |k, v| [k, from_hash(v) ]}]
      end

      unless hash['additionalProperties'].nil?
        s.additional_properties = hash['additionalProperties']
      end

      if hash['values']
        s.values = from_hash(hash['values'])
      end

      s.discriminator = hash['discriminator']

      if hash['mapping']
        s.mapping = Hash[hash['mapping'].map { |k, v| [k, from_hash(v) ]}]
      end

      s
    end

    # Raises a TypeError or ArgumentError if the Schema is not correct according
    # to the JSON Type Definition specification.
    #
    # See the JSON Type Definition specification for more details, but a high
    # level #verify checks such things as:
    #
    # 1. Making sure each of the attributes of the Schema are of the right type,
    # 2. The Schema uses a valid combination of JSON Type Definition keywords,
    # 3. The Schema isn't ambiguous or unsatisfiable.
    # 4. The Schema doesn't make references to nonexistent definitions.
    #
    # If root is specified, then that root is assumed to contain the schema
    # being verified. By default, the Schema is considered its own root, which
    # is usually the desired behavior.
    def verify(root = self)
      self.check_type('metadata', [Hash])
      self.check_type('nullable', [TrueClass, FalseClass])
      self.check_type('definitions', [Hash])
      self.check_type('ref', [String])
      self.check_type('type', [String])
      self.check_type('enum', [Array])
      self.check_type('elements', [Schema])
      self.check_type('properties', [Hash])
      self.check_type('optional_properties', [Hash])
      self.check_type('additional_properties', [TrueClass, FalseClass])
      self.check_type('values', [Schema])
      self.check_type('discriminator', [String])
      self.check_type('mapping', [Hash])

      form_signature = [
        !!ref,
        !!type,
        !!enum,
        !!elements,
        !!properties,
        !!optional_properties,
        !!additional_properties,
        !!values,
        !!discriminator,
        !!mapping,
      ]

      unless VALID_FORMS.include?(form_signature)
        raise ArgumentError.new("invalid schema form: #{self}")
      end

      if root != self && definitions && definitions.any?
        raise ArgumentError.new("non-root definitions: #{definitions}")
      end

      if ref
        if !root.definitions || !root.definitions.key?(ref)
          raise ArgumentError.new("ref to non-existent definition: #{ref}")
        end
      end

      if type && !TYPES.include?(type)
        raise ArgumentError.new("invalid type: #{type}")
      end

      if enum
        if enum.empty?
          raise ArgumentError.new("enum must not be empty: #{self}")
        end

        if enum.any? { |v| !v.is_a?(String) }
          raise ArgumentError.new("enum must contain only strings: #{enum}")
        end

        if enum.size != enum.uniq.size
          raise ArgumentError.new("enum must not contain duplicates: #{enum}")
        end
      end

      if properties && optional_properties
        shared_keys = properties.keys & optional_properties.keys
        if shared_keys.any?
          raise ArgumentError.new("properties and optional_properties share keys: #{shared_keys}")
        end
      end

      if mapping
        mapping.values.each do |s|
          if s.form != :properties
            raise ArgumentError.new("mapping values must be of properties form: #{s}")
          end

          if s.nullable
            raise ArgumentError.new("mapping values must not be nullable: #{s}")
          end

          contains_discriminator = ArgumentError.new("mapping values must not contain discriminator (#{discriminator}): #{s}")

          if s.properties && s.properties.key?(discriminator)
            raise contains_discriminator
          end

          if s.optional_properties && s.optional_properties.key?(discriminator)
            raise contains_discriminator
          end
        end
      end

      definitions.values.each { |s| s.verify(root) } if definitions
      elements.verify(root) if elements
      properties.values.each { |s| s.verify(root) } if properties
      optional_properties.values.each { |s| s.verify(root) } if optional_properties
      values.verify(root) if values
      mapping.values.each { |s| s.verify(root) } if mapping

      self
    end

    # Returns the form that the schema takes on.
    #
    # The return value will be one of :empty, :ref:, :type, :enum, :elements,
    # :properties, :values, or :discriminator.
    #
    # If the schema is not well-formed, i.e. calling #verify on it raises an
    # error, then the return value of #form is not well-defined.
    def form
      return :ref if ref
      return :type if type
      return :enum if enum
      return :elements if elements
      return :properties if properties || optional_properties
      return :values if values
      return :discriminator if discriminator

      :empty
    end

    private

    KEYWORDS = %w[
      metadata
      nullable
      definitions
      ref
      type
      enum
      elements
      properties
      optionalProperties
      additionalProperties
      values
      discriminator
      mapping
    ]

    private_constant :KEYWORDS

    TYPES = %w[
      boolean
      int8
      uint8
      int16
      uint16
      int32
      uint32
      float32
      float64
      string
      timestamp
    ]

    private_constant :TYPES

    VALID_FORMS = [
      # Empty form
      [false, false, false, false, false, false, false, false, false, false],
      # Ref form
      [true, false, false, false, false, false, false, false, false, false],
      # Type form
      [false, true, false, false, false, false, false, false, false, false],
      # Enum form
      [false, false, true, false, false, false, false, false, false, false],
      # Elements form
      [false, false, false, true, false, false, false, false, false, false],
      # Properties form -- properties or optional properties or both, and
      # never additional properties on its own
      [false, false, false, false, true, false, false, false, false, false],
      [false, false, false, false, false, true, false, false, false, false],
      [false, false, false, false, true, true, false, false, false, false],
      [false, false, false, false, true, false, true, false, false, false],
      [false, false, false, false, false, true, true, false, false, false],
      [false, false, false, false, true, true, true, false, false, false],
      # Values form
      [false, false, false, false, false, false, false, true, false, false],
      # Discriminator form
      [false, false, false, false, false, false, false, false, true, true],
    ]

    private_constant :VALID_FORMS

    def check_type(key, classes)
      val = self.send(key)
      unless val.nil? || classes.include?(val.class)
        raise TypeError.new("#{key} must be one of #{classes}, got: #{val}")
      end
    end
  end
end
