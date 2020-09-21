# jtd: JSON Validation for Python

[![Gem](https://img.shields.io/gem/v/jtd)](https://rubygems.org/gems/jtd)

`jtd` is a Ruby implementation of [JSON Type Definition][jtd], a schema language
for JSON. `jtd` primarily gives you two things:

1. Validating input data against JSON Typedef schemas.
2. A Ruby representation of JSON Typedef schemas.

With this package, you can add JSON Typedef-powered validation to your
application, or you can build your own tooling on top of JSON Type Definition.

## Installation

You can install this package with `gem`:

```bash
gem install jtd
```

## Documentation

Detailed API documentation is available online at:

https://rubydoc.info/gems/jtd/JTD

For more high-level documentation about JSON Typedef in general, or JSON Typedef
in combination with Python in particular, see:

* [The JSON Typedef Website][jtd]
* ["Validating JSON in Ruby with JSON Typedef"][jtd-ruby-validation]

## Basic Usage

> For a more detailed tutorial and guidance on how to integrate `jtd` in your
> application, see ["Validating JSON in Ruby with JSON
> Typedef"][jtd-ruby-validation] in the JSON Typedef docs.

Here's an example of how you can use this package to validate JSON data against
a JSON Typedef schema:

```ruby
require 'jtd'

schema = JTD::Schema.from_hash({
  'properties' => {
    'name' => { 'type' => 'string' },
    'age' => { 'type' => 'uint32' },
    'phones' => {
      'elements' => {
        'type' => 'string'
      }
    }
  }
})

# JTD::validate returns an array of validation errors. If there were no problems
# with the input, it returns an empty array.

# Outputs: []
p JTD::validate(schema, {
  'name' => 'John Doe',
  'age' => 43,
  'phones' => ['+44 1234567', '+44 2345678'],
})

# This next input has three problems with it:
#
# 1. It's missing "name", which is a required property.
# 2. "age" is a string, but it should be an integer.
# 3. "phones[1]" is a number, but it should be a string.
#
# Each of those errors corresponds to one of the errors returned by validate.

# Outputs:
#
# [
#   #<struct JTD::ValidationError
#     instance_path=[],
#     schema_path=["properties", "name"]
#   >,
#   #<struct JTD::ValidationError
#     instance_path=["age"],
#     schema_path=["properties", "age", "type"]
#   >,
#   #<struct JTD::ValidationError
#     instance_path=["phones", "1"],
#     schema_path=["properties", "phones", "elements", "type"]
#   >
# ]
p JTD::validate(schema, {
  'age' => '43',
  'phones' => ['+44 1234567', 442345678],
})
```

## Advanced Usage: Limiting Errors Returned

By default, `JTD::validate` returns every error it finds. If you just care about
whether there are any errors at all, or if you can't show more than some number
of errors, then you can get better performance out of `JTD::validate` using the
`max_errors` option.

For example, taking the same example from before, but limiting it to 1 error, we
get:

```python
# Outputs:
#
# [#<struct JTD::ValidationError instance_path=[], schema_path=["properties", "name"]>]
options = JTD::ValidationOptions.new(max_errors: 1)
p JTD::validate(schema, {
  'age' => '43',
  'phones' => ['+44 1234567', 442345678],
}, options)
```

## Advanced Usage: Handling Untrusted Schemas

If you want to run `jtd` against a schema that you don't trust, then you should:

1. Ensure the schema is well-formed, using the `#verify` method on
   `JTD::Schema`. That will check things like making sure all `ref`s have
   corresponding definitions.

2. Call `JTD::validate` with the `max_depth` option. JSON Typedef lets you write
   recursive schemas -- if you're evaluating against untrusted schemas, you
   might go into an infinite loop when evaluating against a malicious input,
   such as this one:

   ```json
   {
     "ref": "loop",
     "definitions": {
       "loop": {
         "ref": "loop"
       }
     }
   }
   ```

   The `max_depth` option tells `JTD::validate` how many `ref`s to follow
   recursively before giving up and raising `JTD::MaxDepthExceededError`.

Here's an example of how you can use `jtd` to evaluate data against an untrusted
schema:

```ruby
require 'jtd'

# validate_untrusted returns true if `data` satisfies `schema`, and false if it
# does not. Throws an error if `schema` is invalid, or if validation goes in an
# infinite loop.
def validate_untrusted(schema, data)
  schema.verify()

  # You should tune max_depth to be high enough that most legitimate schemas
  # evaluate without errors, but low enough that an attacker cannot cause a
  # denial of service attack.
  options = JTD::ValidationOptions.new(max_depth: 32)
  JTD::validate(schema, data, options).empty?
end

# Returns true
validate_untrusted(JTD::Schema.from_hash({ 'type' => 'string' }), 'foo')

# Returns false
validate_untrusted(JTD::Schema.from_hash({ 'type' => 'string' }), nil)

# Raises ArgumentError (invalid type: nonsense)
validate_untrusted(JTD::Schema.from_hash({ 'type' => 'nonsense' }), 'foo')

# Raises JTD::MaxDepthExceededError (max depth exceeded during JTD::validate)
validate_untrusted(JTD::Schema.from_hash({
  'definitions' => {
    'loop' => { 'ref' => 'loop' },
  },
  'ref' => 'loop',
}), nil)
```

[jtd]: https://jsontypedef.com
[jtd-ruby-validation]: https://jsontypedef.com/docs/ruby/validation
