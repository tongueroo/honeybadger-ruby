require 'socket'

module Honeybadger
  class Notice
    # The exception that caused this notice, if any
    attr_reader :exception

    # The backtrace from the given exception or hash.
    attr_reader :backtrace

    # The name of the class of error (such as RuntimeError)
    attr_reader :error_class

    # The name of the server environment (such as "production")
    attr_reader :environment_name

    # CGI variables such as HTTP_METHOD
    attr_reader :cgi_data

    # The message from the exception, or a general description of the error
    attr_reader :error_message

    # See Configuration#backtrace_filters
    attr_reader :backtrace_filters

    # See Configuration#params_filters
    attr_reader :params_filters

    # A hash of parameters from the query string or post body.
    attr_reader :parameters
    alias_method :params, :parameters

    # The component (if any) which was used in this request (usually the controller)
    attr_reader :component
    alias_method :controller, :component

    # The action (if any) that was called in this request
    attr_reader :action

    # A hash of session data from the request
    attr_reader :session_data

    # The path to the project that caused the error (usually Rails.root)
    attr_reader :project_root

    # The URL at which the error occurred (if any)
    attr_reader :url

    # See Configuration#ignore
    attr_reader :ignore

    # See Configuration#ignore_by_filters
    attr_reader :ignore_by_filters

    # The name of the notifier library sending this notice, such as "Honeybadger Notifier"
    attr_reader :notifier_name

    # The version number of the notifier library sending this notice, such as "2.1.3"
    attr_reader :notifier_version

    # A URL for more information about the notifier library sending this notice
    attr_reader :notifier_url

    # The host name where this error occurred (if any)
    attr_reader :hostname

    # The user affected by the exception, if available
    attr_reader :user

    def initialize(args)
      self.args         = args
      self.exception    = args[:exception]
      self.project_root = args[:project_root]
      self.url          = args[:url] || rack_env(:url)

      self.notifier_name    = args[:notifier_name]
      self.notifier_version = args[:notifier_version]
      self.notifier_url     = args[:notifier_url]

      self.ignore              = args[:ignore]              || []
      self.ignore_by_filters   = args[:ignore_by_filters]   || []
      self.backtrace_filters   = args[:backtrace_filters]   || []
      self.params_filters      = args[:params_filters]      || []
      self.parameters          = args[:parameters] ||
                                   action_dispatch_params ||
                                   rack_env(:params) ||
                                   {}
      self.component           = args[:component] || args[:controller] || parameters['controller']
      self.action              = args[:action] || parameters['action']

      self.environment_name = args[:environment_name]
      self.cgi_data         = args[:cgi_data] || args[:rack_env]
      self.user             = args[:user]
      self.backtrace        = Backtrace.parse(exception_attribute(:backtrace, caller), :filters => self.backtrace_filters)
      self.error_class      = exception_attribute(:error_class) {|exception| exception.class.name }
      self.error_message    = exception_attribute(:error_message, 'Notification') do |exception|
        "#{exception.class.name}: #{exception.message}"
      end

      self.hostname        = local_hostname

      also_use_rack_params_filters
      find_session_data
      clean_params
      clean_rack_request_data
    end

    # Public: Template used to create JSON payload
    #
    # Returns JSON representation of notice
    def as_json(options = {})
      {
        :notifier => {
          :name => notifier_name,
          :url => notifier_url,
          :version => notifier_version
        },
        :error => {
          :class => error_class,
          :message => error_message,
          :backtrace => backtrace
        },
        :request => {
          :url => url,
          :component => component,
          :action => action,
          :params => parameters,
          :session => session_data,
          :cgi_data => cgi_data,
          :user => user
        },
        :server => {
          :project_root => project_root,
          :environment_name => environment_name,
          :hostname => hostname
        }
      }
    end

    # Public: Creates JSON
    #
    # Returns valid JSON representation of notice
    def to_json(*a)
      as_json.to_json(*a)
    end

    # Determines if this notice should be ignored
    def ignore?
      ignored_class_names.include?(error_class) ||
        ignore_by_filters.any? {|filter| filter.call(self) }
    end

    # Public: Allows properties to be accessed using a hash-like syntax
    #
    # method - The given key for an attribute
    #
    # Examples:
    #
    #   notice[:error_message]
    #
    # Returns the attribute value, or self if given +:request+
    def [](method)
      case method
      when :request
        self
      else
        send(method)
      end
    end

    private

    attr_writer :exception, :backtrace, :error_class, :error_message,
      :backtrace_filters, :parameters, :params_filters, :environment_filters,
      :session_data, :project_root, :url, :ignore, :ignore_by_filters,
      :notifier_name, :notifier_url, :notifier_version, :component, :action,
      :cgi_data, :environment_name, :hostname, :user

    # Private: Arguments given in the initializer
    attr_accessor :args

    # Private: Gets a property named +attribute+ of an exception, either from an actual
    # exception or a hash.
    #
    # If an exception is available, #from_exception will be used. Otherwise,
    # a key named +attribute+ will be used from the #args.
    #
    # If no exception or hash key is available, +default+ will be used.
    def exception_attribute(attribute, default = nil, &block)
      (exception && from_exception(attribute, &block)) || args[attribute] || default
    end

    # Private: Gets a property named +attribute+ from an exception.
    #
    # If a block is given, it will be used when getting the property from an
    # exception. The block should accept and exception and return the value for
    # the property.
    #
    # If no block is given, a method with the same name as +attribute+ will be
    # invoked for the value.
    def from_exception(attribute)
      if block_given?
        yield(exception)
      else
        exception.send(attribute)
      end
    end

    # Private: Removes non-serializable data from the given attribute.
    # See #clean_unserializable_data
    def clean_unserializable_data_from(attribute)
      self.send(:"#{attribute}=", clean_unserializable_data(send(attribute)))
    end

    # Private: Removes non-serializable data. Allowed data types are strings, arrays,
    # and hashes. All other types are converted to strings.
    # TODO: move this onto Hash
    def clean_unserializable_data(data, stack = [])
      return "[possible infinite recursion halted]" if stack.any?{|item| item == data.object_id }

      if data.respond_to?(:to_hash)
        data.to_hash.inject({}) do |result, (key, value)|
          result.merge(key => clean_unserializable_data(value, stack + [data.object_id]))
        end
      elsif data.respond_to?(:to_ary)
        data.to_ary.collect do |value|
          clean_unserializable_data(value, stack + [data.object_id])
        end
      else
        data.to_s
      end
    end

    # Private: Replaces the contents of params that match params_filters.
    # TODO: extract this to a different class
    def clean_params
      clean_unserializable_data_from(:parameters)
      filter(parameters)
      if cgi_data
        clean_unserializable_data_from(:cgi_data)
        filter(cgi_data)
      end
      if session_data
        clean_unserializable_data_from(:session_data)
        filter(session_data)
      end
    end

    def clean_rack_request_data
      if cgi_data
        cgi_data.delete("rack.request.form_vars")
      end
    end

    def filter(hash)
      if params_filters
        hash.each do |key, value|
          if filter_key?(key)
            hash[key] = "[FILTERED]"
          elsif value.respond_to?(:to_hash)
            filter(hash[key])
          end
        end
      end
    end

    def filter_key?(key)
      params_filters.any? do |filter|
        key.to_s.eql?(filter.to_s)
      end
    end

    def find_session_data
      self.session_data = args[:session_data] || args[:session] || rack_session || {}
      self.session_data = session_data[:data] if session_data[:data]
    end

    # Private: Converts the mixed class instances and class names into just names
    # TODO: move this into Configuration or another class
    def ignored_class_names
      ignore.collect do |string_or_class|
        if string_or_class.respond_to?(:name)
          string_or_class.name
        else
          string_or_class
        end
      end
    end

    def rack_env(method)
      rack_request.send(method) if rack_request
    end

    def rack_request
      @rack_request ||= if args[:rack_env]
        ::Rack::Request.new(args[:rack_env])
      end
    end

    def action_dispatch_params
      args[:rack_env]['action_dispatch.request.parameters'] if args[:rack_env]
    end

    def rack_session
      args[:rack_env]['rack.session'] if args[:rack_env]
    end

    def also_use_rack_params_filters
      if args[:rack_env]
        @params_filters ||= []
        @params_filters += rack_request.env["action_dispatch.parameter_filter"] || []
      end
    end

    def local_hostname
      Socket.gethostname
    end
  end
end