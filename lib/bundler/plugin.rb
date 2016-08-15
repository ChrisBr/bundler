# frozen_string_literal: true

module Bundler
  module Plugin
    autoload :API,        "bundler/plugin/api"
    autoload :DSL,        "bundler/plugin/dsl"
    autoload :Index,      "bundler/plugin/index"
    autoload :Installer,  "bundler/plugin/installer"
    autoload :SourceList, "bundler/plugin/source_list"

    class MalformattedPlugin < PluginError; end
    class UndefinedCommandError < PluginError; end
    class UnknownSourceError < PluginError; end

    PLUGIN_FILE_NAME = "plugins.rb".freeze

  module_function

    @commands = {}
    @sources = {}

    # Installs a new plugin by the given name
    #
    # @param [Array<String>] names the name of plugin to be installed
    # @param [Hash] options various parameters as described in description.
    #               Refer to cli/plugin for available options
    def install(names, options)
      specs = Installer.new.install(names, options)

      save_plugins names, specs
    rescue PluginError => e
      specs.values.map {|spec| Bundler.rm_rf(spec.full_gem_path) } if specs
      Bundler.ui.error "Failed to install plugin #{name}: #{e.message}\n  #{e.backtrace[0]}"
    end

    # Evaluates the Gemfile with a limited DSL and installs the plugins
    # specified by plugin method
    #
    # @param [Pathname] gemfile path
    # @param [Proc] block that can be evaluated for (inline) Gemfile
    def gemfile_install(gemfile = nil, &inline)
      builder = DSL.new
      if block_given?
        builder.instance_eval(&inline)
      else
        builder.eval_gemfile(gemfile)
      end
      definition = builder.to_definition(nil, true)

      return if definition.dependencies.empty?

      plugins = definition.dependencies.map(&:name).reject {|p| index.installed? p }
      installed_specs = Installer.new.install_definition(definition)

      save_plugins plugins, installed_specs, builder.inferred_plugins
    rescue => e
      Bundler.ui.error "Failed to install plugin: #{e.message}\n  #{e.backtrace[0]}"
      raise
    end

    # The index object used to store the details about the plugin
    def index
      @index ||= Index.new
    end

    # The directory root for all plugin related data
    #
    # Points to root in app_config_path if ran in an app else points to the one
    # in user_bundle_path
    def root
      @root ||= if SharedHelpers.in_bundle?
        local_root
      else
        global_root
      end
    end

    def local_root
      Bundler.app_config_path.join("plugin")
    end

    # The global directory root for all plugin related data
    def global_root
      Bundler.user_bundle_path.join("plugin")
    end

    # The cache directory for plugin stuffs
    def cache
      @cache ||= root.join("cache")
    end

    # To be called via the API to register to handle a command
    def add_command(command, cls)
      @commands[command] = cls
    end

    # Checks if any plugin handles the command
    def command?(command)
      !index.command_plugin(command).nil?
    end

    # To be called from Cli class to pass the command and argument to
    # approriate plugin class
    def exec_command(command, args)
      raise UndefinedCommandError, "Command `#{command}` not found" unless command? command

      load_plugin index.command_plugin(command) unless @commands.key? command

      @commands[command].new.exec(command, args)
    end

    # To be called via the API to register to handle a source plugin
    def add_source(source, cls)
      @sources[source] = cls
    end

    # Checks if any plugin declares the source
    def source?(name)
      !index.source_plugin(name.to_s).nil?
    end

    # @return [Class] that handles the source. The calss includes API::Source
    def source(name)
      raise UnknownSourceError, "Source #{name} not found" unless source? name

      load_plugin(index.source_plugin(name)) unless @sources.key? name

      @sources[name]
    end

    # @param [Hash] The options that are present in the lock file
    # @return [API::Source] the instance of the class that handles the source
    #                       type passed in locked_opts
    def source_from_lock(locked_opts)
      src = source(locked_opts["type"])

      src.new(locked_opts.merge("uri" => locked_opts["remote"]))
    end

    # currently only intended for specs
    #
    # @return [String, nil] installed path
    def installed?(plugin)
      Index.new.installed?(plugin)
    end

    # Used by specs
    def reset!
      instance_variables.each {|i| remove_instance_variable(i) }

      @sources = {}
      @commands = {}
    end

    # Post installation processing and registering with index
    #
    # @param [Array<String>] plugins list to be installed
    # @param [Hash] specs of plugins mapped to installation path (currently they
    #               contain all the installed specs, including plugins)
    # @param [Array<String>] names of inferred source plugins that can be ignored
    def save_plugins(plugins, specs, optional_plugins = [])
      plugins.each do |name|
        spec = specs[name]
        validate_plugin! Pathname.new(spec.full_gem_path)
        installed = register_plugin name, spec, optional_plugins.include?(name)
        Bundler.ui.info "Installed plugin #{name}" if installed
      end
    end

    # Checks if the gem is good to be a plugin
    #
    # At present it only checks whether it contains plugins.rb file
    #
    # @param [Pathname] plugin_path the path plugin is installed at
    # @raise [MalformattedPlugin] if plugins.rb file is not found
    def validate_plugin!(plugin_path)
      plugin_file = plugin_path.join(PLUGIN_FILE_NAME)
      raise MalformattedPlugin, "#{PLUGIN_FILE_NAME} was not found in the plugin." unless plugin_file.file?
    end

    # Runs the plugins.rb file in an isolated namespace, records the plugin
    # actions it registers for and then passes the data to index to be stored.
    #
    # @param [String] name the name of the plugin
    # @param [Specification] spec of installed plugin
    # @param [Boolean] optional_plugin, removed if there is conflict with any
    #                     other plugin (used for default source plugins)
    #
    # @raise [MalformattedPlugin] if plugins.rb raises any error
    def register_plugin(name, spec, optional_plugin = false)
      commands = @commands
      sources = @sources

      @commands = {}
      @sources = {}

      load_paths = spec.load_paths
      add_to_load_path(load_paths)
      path = Pathname.new spec.full_gem_path

      begin
        load path.join(PLUGIN_FILE_NAME), true
      rescue StandardError => e
        raise MalformattedPlugin, "#{e.class}: #{e.message}"
      end

      if optional_plugin && @sources.keys.any? {|s| source? s }
        Bundler.rm_rf(path)
        false
      else
        index.register_plugin name, path.to_s, load_paths, @commands.keys, @sources.keys
        true
      end
    ensure
      @commands = commands
      @sources = sources
    end

    # Executes the plugins.rb file
    #
    # @param [String] name of the plugin
    def load_plugin(name)
      # Need to ensure before this that plugin root where the rest of gems
      # are installed to be on load path to support plugin deps. Currently not
      # done to avoid conflicts
      path = index.plugin_path(name)

      add_to_load_path(index.load_paths(name))

      load path.join(PLUGIN_FILE_NAME)
    rescue => e
      Bundler.ui.error "Failed loading plugin #{name}: #{e.message}"
      raise
    end

    def add_to_load_path(load_paths)
      if insert_index = Bundler.rubygems.load_path_insert_index
        $LOAD_PATH.insert(insert_index, *load_paths)
      else
        $LOAD_PATH.unshift(*load_paths)
      end
    end

    class << self
      private :load_plugin, :register_plugin, :save_plugins, :validate_plugin!,
        :add_to_load_path
    end
  end
end
