require 'json'

RSpec.describe JTD do
  describe 'validate' do
    it 'supports max depth' do
      schema = JTD::Schema.from_hash({
        'definitions' => { 'loop' => { 'ref' => 'loop' }},
        'ref' => 'loop',
      }).verify

      expect do
        JTD::validate(schema, nil, JTD::ValidationOptions.new(max_depth: 32))
      end.to raise_error JTD::MaxDepthExceededError
    end

    it 'supports max errors' do
      schema = JTD::Schema.from_hash({
        'elements' => { 'type' => 'string' }
      }).verify

      options = JTD::ValidationOptions.new(max_errors: 3)
      expect(JTD::validate(schema, [nil] * 5, options).size).to eq 3
    end

    describe 'spec tests' do
      test_cases = File.read('json-typedef-spec/tests/validation.json')
      test_cases = JSON.parse(test_cases)

      test_cases.each do |name, test_case|
        it name do
          schema = JTD::Schema.from_hash(test_case['schema']).verify
          instance = test_case['instance']
          expected_errors = test_case['errors'].map do |e|
            JTD::ValidationError.from_hash(e)
          end

          actual_errors = JTD::validate(schema, instance)
          expect(actual_errors).to eq expected_errors
        end
      end
    end
  end
end
