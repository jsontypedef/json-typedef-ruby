require "json"

RSpec.describe JTD::Schema do
  describe 'spec tests' do
    test_cases = File.read('json-typedef-spec/tests/invalid_schemas.json')
    test_cases = JSON.parse(test_cases)
    test_cases.each do |test_case, schema|
      it test_case do
        errored = false

        begin
          JTD::Schema.from_hash(schema).verify
        rescue NoMethodError, TypeError, ArgumentError
          errored = true
        end

        expect(errored).to be true
      end
    end
  end
end
