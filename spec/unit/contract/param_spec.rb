# frozen_string_literal: true

require_relative '../../spec_helper'

RSpec.describe RestClient::Contract::Param do
  let(:param) { described_class.new(:x, type, **options) }
  let(:type) { nil }
  let(:options) { {} }

  describe 'definition-time validation' do
    it 'rejects unknown symbols' do
      expect {
        described_class.new(:x, :nonsense)
      }.to raise_error(
        RestClient::Contract::InvalidDefinition,
        /unsupported param type :nonsense/
      )
    end

    it 'rejects non-class, non-proc types' do
      expect {
        described_class.new(:x, 'String')
      }.to raise_error(RestClient::Contract::InvalidDefinition, /expected a Class, Proc or supported symbol/)
    end

    it 'rejects an inclusion that does not respond to include?' do
      expect {
        described_class.new(:x, Integer, inclusion: 1)
      }.to raise_error(RestClient::Contract::InvalidDefinition, /inclusion must respond to #include\?/)
    end

    it 'maps symbol aliases to classes' do
      expect(described_class.new(:x, :string).type).to eq String
      expect(described_class.new(:x, :integer).type).to eq Integer
      expect(described_class.new(:x, :float).type).to eq Float
      expect(described_class.new(:x, :array).type).to eq Array
      expect(described_class.new(:x, :hash).type).to eq Hash
      expect(described_class.new(:x, :boolean).type).to eq :boolean
    end

    it 'maps TrueClass/FalseClass to the boolean type' do
      expect(described_class.new(:x, TrueClass).type).to eq :boolean
      expect(described_class.new(:x, FalseClass).type).to eq :boolean
    end
  end

  describe '#process!' do
    subject { param.process!(value) }

    context 'untyped params' do
      it 'passes values through untouched' do
        expect(described_class.new(:x).process!('anything')).to eq 'anything'
      end
    end

    context 'String params' do
      let(:type) { String }

      it { expect { param.process!(42) }.to raise_error(RestClient::Contract::InvalidParam, /param :x: expected String, got Integer \(42\)/) }

      it 'accepts strings' do
        expect(param.process!('hi')).to eq 'hi'
      end

      it 'coerces symbols' do
        expect(param.process!(:hi)).to eq 'hi'
      end
    end

    context 'Integer params' do
      let(:type) { Integer }

      it { expect { param.process!('abc') }.to raise_error(RestClient::Contract::InvalidParam, /expected Integer, got String \("abc"\)/) }
      it { expect { param.process!(3.5) }.to raise_error(RestClient::Contract::InvalidParam, /expected Integer, got Float/) }
      it { expect { param.process!(nil) }.to raise_error(RestClient::Contract::InvalidParam, /expected Integer, got nil/) }

      it 'accepts integers' do
        expect(param.process!(7)).to eq 7
      end

      it 'coerces integral floats' do
        expect(param.process!(7.0)).to eq 7
      end

      it 'coerces numeric strings' do
        expect(param.process!('-12')).to eq(-12)
      end
    end

    context 'Float params' do
      let(:type) { Float }

      it 'accepts floats and integers' do
        expect(param.process!(1.5)).to eq 1.5
        expect(param.process!(2)).to eq 2.0
      end

      it 'coerces numeric strings' do
        expect(param.process!('1.5e3')).to eq 1500.0
      end

      it 'rejects junk strings' do
        expect { param.process!('nope') }.to raise_error(RestClient::Contract::InvalidParam, /expected Float/)
      end
    end

    context 'boolean params' do
      let(:type) { :boolean }

      it 'accepts real booleans' do
        expect(param.process!(true)).to be true
        expect(param.process!(false)).to be false
      end

      it 'coerces strings' do
        expect(param.process!('true')).to be true
        expect(param.process!('YES')).to be true
        expect(param.process!('off')).to be false
      end

      it 'coerces 1/0' do
        expect(param.process!(1)).to be true
        expect(param.process!(0)).to be false
      end

      it 'rejects everything else' do
        expect { param.process!('maybe') }.to raise_error(RestClient::Contract::InvalidParam, /expected boolean/)
      end
    end

    context 'Array params' do
      let(:type) { Array }

      it 'accepts arrays' do
        expect(param.process!([1, 2])).to eq [1, 2]
      end

      it 'wraps scalars' do
        expect(param.process!('a')).to eq ['a']
      end
    end

    context 'Hash params' do
      let(:type) { Hash }

      it 'accepts hashes' do
        expect(param.process!(a: 1)).to eq(a: 1)
      end

      it 'rejects non-hashes' do
        expect { param.process!([:a]) }.to raise_error(RestClient::Contract::InvalidParam, /expected Hash/)
      end
    end

    context 'Proc params' do
      let(:type) { ->(v) { v.to_s.reverse } }

      it 'uses the proc return value' do
        expect(param.process!(123)).to eq '321'
      end

      it 'wraps proc failures in InvalidParam' do
        param = described_class.new(:x, ->(v) { raise ArgumentError, 'bad' })
        expect { param.process!('x') }.to raise_error(
          RestClient::Contract::InvalidParam, /custom coercion failed: ArgumentError: bad/
        )
      end
    end

    context 'custom Class params' do
      let(:castable) do
        Class.new do
          attr_reader :value

          def initialize(value)
            @value = value
          end

          def self.name
            'Money'
          end

          def self.restclient_coerce(value)
            raise ArgumentError, 'not money' unless value.to_s.match?(/\A\d+\z/)

            new(value.to_i)
          end
        end
      end
      let(:type) { castable }

      it 'passes through instances of the class' do
        money = castable.new(5)
        expect(param.process!(money)).to be money
      end

      it 'uses Class#restclient_coerce when defined' do
        expect(param.process!('42').value).to eq 42
      end

      it 'rejects values the class cannot coerce' do
        expect { param.process!('lots') }.to raise_error(
          RestClient::Contract::InvalidParam, /custom coercion failed: ArgumentError: not money/
        )
      end
    end

    context 'with inclusion' do
      let(:type) { Integer }
      let(:options) { { inclusion: (1..10) } }

      it 'accepts values inside the range' do
        expect(param.process!(5)).to eq 5
      end

      it 'validates after coercion' do
        expect(param.process!('5')).to eq 5
      end

      it 'rejects values outside the range' do
        expect { param.process!(99) }.to raise_error(
          RestClient::Contract::InvalidParam, /param :x: value 99 is not in 1\.\.10/
        )
      end
    end

    context 'with coerce: false' do
      let(:type) { Integer }
      let(:options) { { coerce: false } }

      it 'accepts exact types' do
        expect(param.process!(5)).to eq 5
      end

      it 'rejects anything that is not already the type' do
        expect { param.process!('5') }.to raise_error(RestClient::Contract::InvalidParam, /expected Integer, got String/)
      end
    end
  end

  describe 'defaults' do
    it 'reports whether a default is declared' do
      expect(described_class.new(:x).has_default?).to be false
      expect(described_class.new(:x, default: nil).has_default?).to be true
      expect(described_class.new(:x, default: 3).has_default?).to be true
    end

    it 'calls proc defaults lazily' do
      calls = 0
      param = described_class.new(:x, default: -> { calls += 1; calls })
      expect(param.default_value).to eq 1
      expect(param.default_value).to eq 2
    end
  end

  describe '#required?' do
    it 'defaults to optional' do
      expect(described_class.new(:x).required?).to be false
      expect(described_class.new(:x, required: true).required?).to be true
    end
  end

  describe '#to_s' do
    it 'summarizes the param' do
      param = described_class.new(:page, Integer, inclusion: (1..100))
      expect(param.to_s).to eq 'Integer, in 1..100'
    end
  end
end
