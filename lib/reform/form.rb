require 'forwardable'
require 'ostruct'

require 'reform/composition'
require 'reform/representer'

module Reform
  class Form
    extend Forwardable
    # reasons for delegation:
    # presentation: this object is used in the presentation layer by #form_for.
    # problem: #form_for uses respond_to?(:email_before_type_cast) which goes to an internal hash in the actual record.
    # validation: this object also contains the validation rules itself, should be separated.

    # Allows using property and friends in the Form itself. Forwarded to the internal representer_class.
    module PropertyMethods
      extend Forwardable

      def property(name, options={}, &block)
        definition = representer_class.property(name, options, &block)
        setup_form_definition(definition) if block_given?
        create_accessor(name)
      end

      def collection(name, options={}, &block)
        options[:form_collection] = true

        property(name, options, &block)
      end

      def properties(names, *args)
        names.each { |name| property(name, *args) }
      end

      def setup_form_definition(definition)
        definition.options[:form] = definition.options.delete(:extend)

        definition.options[:parse_strategy] = :sync
        definition.options[:instance] = true # just to make typed? work
      end

      def representer_class
        @representer_class ||= Class.new(Reform::Representer)
      end

    private
      def create_accessor(name)
        delegate [name, "#{name}="] => :fields
      end
    end
    extend PropertyMethods


    def initialize(model)
      @model  = model # we need this for #save.
      @fields = setup_fields(model)  # delegate all methods to Fields instance.
    end

    def validate(params)
      # here it would be cool to have a validator object containing the validation rules representer-like and then pass it the formed model.
      from_hash(params)

      res = valid?  # this validates on <Fields> using AM::Validations, currently.

      mapper.new(@fields).nested_forms do |attr, form|
        next if form.is_a?(Array) # FIXME!
        next if form.valid? # FIXME: we have to call validate here, otherwise this works only one level deep.

        res = false # res &= form.valid?
        errors.add(attr.from, form.errors.messages)
      end

      res
    end

    def save
      # DISCUSS: we should never hit @mapper here (which writes to the models) when a block is passed.
      return yield self, to_nested_hash if block_given?

      save_to_models
    end

    # Use representer to return current key-value form hash.
    def to_hash(*)
      mapper.new(self).to_hash
    end

    def to_nested_hash
      symbolize_keys(to_hash)
    end

    def from_hash(params, *args)
      mapper.new(self).from_hash(params) # sets form properties found in params on self.
    end

  private
    attr_accessor :model, :fields

    def symbolize_keys(hash)
      hash.inject({}){|memo,(k,v)| memo[k.to_sym] = v; memo}
    end

    def mapper
      self.class.representer_class
    end

    def setup_fields(model)
      representer = Class.new(mapper).new(model)

      setup_nested_forms(representer)

      create_fields(representer.fields, representer.to_hash)
    end

    def setup_nested_forms(representer)
      # TODO: we should simply give a FormBuilder instance to representer.to_hash that does this kind of mapping:
      # after this, Fields contains scalars and Form instances and Forms with form instances.
      representer.nested_forms do |attr, model|
        form_class = attr.options[:form]

        attr.options.merge!(
          :getter   => lambda do |*|
            nested_model  = send(attr.getter) # decorated.hit # TODO: use bin.get

            if attr.options[:form_collection]
              Forms.new(nested_model.collect { |mdl| form_class.new(mdl)})
            else
              form_class.new(nested_model)
            end
          end,
          :instance => false, # that's how we make it non-typed?.
        )
      end

      # DISCUSS: this would be cool in representable:
      # to_hash(hit: lambda { |value| form_class.new(..) })

      # steps:
      # - bin.get
      # - map that: Forms.new( orig ) <-- override only this in representable (how?)
      # - mapped.to_hash
    end


    require "representable/hash/collection"
    class Forms < Array
      def valid?
        each { |frm| frm.valid? }
      end

      # this gives us each { to_hash }
      include Representable::Hash::Collection
      items :parse_strategy => :sync, :instance => true
    end


    def create_fields(field_names, fields)
      Fields.new(field_names, fields)
    end

    def save_to_models
      representer = mapper.new(model)

      representer.nested_forms do |attr, model|
        attr.options.merge!(
          :decorator => attr.options[:form].representer_class
        )

        if attr.options[:form_collection]
          attr.options.merge!(
            :collection => true
          )
        end
      end

      representer.from_hash(to_hash)
    end

    # FIXME: make AM optional.
    require 'active_model'
    include ActiveModel::Validations

    module Errors
      module MessagesMethod
        def messages
          self
        end
      end

      def errors
        return super unless ::ActiveModel::VERSION::MAJOR == 3 and ::ActiveModel::VERSION::MINOR == 0
        super.extend(MessagesMethod) # Rails 3.0 fix. move to VersionStrategy when we have more of these.
      end
    end
    include Errors
  end

  # Keeps values of the form fields. What's in here is to be displayed in the browser!
  # we need this intermediate object to display both "original values" and new input from the form after submitting.
  class Fields < OpenStruct
    def initialize(properties, values={})
      fields = properties.inject({}) { |hsh, attr| hsh.merge!(attr => nil) }
      super(fields.merge!(values))  # TODO: stringify value keys!
    end
  end
end
