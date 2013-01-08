class EApp

  # Rack interface to all found controllers
  #
  # @example config.ru
  #    module App
  #      class Forum < E
  #        map '/forum'
  #
  #        # ...
  #      end
  #
  #      class Blog < E
  #        map '/blog'
  #
  #        # ...
  #      end
  #    end
  #
  #    run EApp
  def self.call env
    new(:automount).call(env)
  end

  def initialize automount = false, &proc
    @routes = {}
    @controllers = automount ? discover_controllers : []
    @mounted_controllers = []
    @controllers.each {|c| mount_controller c}
    proc && self.instance_exec(&proc)
  end

  # mount a controller or a namespace(a module, a class or a regexp) containing controllers.
  # proc given here will be executed inside given controller/namespace,
  # as well as any global setup defined before this method will be called.
  def mount namespace_or_app, *roots, &setup
    extract_controllers(namespace_or_app).each {|c| mount_controller c, *roots, &setup}
    self
  end

  # proc given here will be executed inside ALL CONTROLLERS!
  # used to setup multiple controllers at once.
  #
  # @note this method should be called before mounting controllers
  #
  # @example
  #   #class News < E
  #     # ...
  #   end
  #   class Articles < E
  #     # ...
  #   end
  #
  #   # this will work correctly
  #   app = EApp.new
  #   app.global_setup { controllers setup }
  #   app.mount News
  #   app.mount Articles
  #   app.run
  #
  #   # and this will NOT!
  #   app = EApp.new
  #   app.mount News
  #   app.mount Articles
  #   app.global_setup { controllers setup }
  #   app.run
  #
  def global_setup &proc
    @global_setup = proc
    self
  end
  alias setup_controllers global_setup
  alias setup global_setup

  # displays URLs the app will respond to,
  # with controller and action that serving each URL.
  def url_map opts = {}
    map = {}
    sorted_routes.each do |r|
      @routes[r].each_pair { |rm, as| (map[r] ||= {})[rm] = as.dup }
    end

    def map.to_s
      out = []
      self.each_pair do |route, request_methods|
        next if route.source.size == 0
        out << "%s\n" % route.source
        request_methods.each_pair do |request_method, route_setup|
          out << "  %s%s" % [request_method, ' ' * (10 - request_method.size)]
          out << "%s#%s\n" % [route_setup[:ctrl], route_setup[:action]]
        end
        out << "\n"
      end
      out.join
    end
    map
  end
  alias urlmap url_map

  # by default, Espresso will use WEBrick server.
  # pass :server option and any option accepted by selected(or default) server:
  #
  # @example use Thin server with its default port
  #   app.run :server => :Thin
  # @example use EventedMongrel server with custom options
  #   app.run :server => :EventedMongrel, :port => 9090, :num_processors => 1000
  #
  # @param [Hash] opts
  # @option opts [Symbol]  :server (:WEBrick) web server
  # @option opts [Integer] :port   (5252)
  # @option opts [String]  :host   (0.0.0.0)
  def run opts = {}
    server = opts.delete(:server)
    (server && Rack::Handler.const_defined?(server)) || (server = HTTP__DEFAULT_SERVER)

    port = opts.delete(:port)
    opts[:Port] ||= port || HTTP__DEFAULT_PORT

    host = opts.delete(:host) || opts.delete(:bind)
    opts[:Host] = host if host

    Rack::Handler.const_get(server).run app, opts
  end

  def call env
    app.call env
  end

  private
  def app
    @app ||= middleware.reverse.inject(lambda {|env| call!(env)}) {|a,e| e[a]}
  end

  def call! env
    sorted_routes.each_pair do |regexp, route|
      if matches = regexp.match(env[ENV__PATH_INFO].to_s)

        if route_setup = route[env[ENV__REQUEST_METHOD]]

          if route_setup[:rewriter]
            rewriter = EspressoFrameworkRewriter.new(*matches.captures, &route_setup[:rewriter])
            return rewriter.call(env)
          elsif pi = matches[1]

            env[ENV__SCRIPT_NAME] = (route_setup[:path]).freeze
            env[ENV__PATH_INFO]   = (path_ok?(pi) ? pi : '/' << pi).freeze

            epi, format = nil
            (fr = route_setup[:format_regexp]) && (epi, format = pi.split(fr))
            env[ENV__ESPRESSO_PATH_INFO] = epi
            env[ENV__ESPRESSO_FORMAT]    = format

            app = Rack::Builder.new
            app.run route_setup[:ctrl].new(route_setup[:action])
            route_setup[:ctrl].middleware.each {|w,a,p| app.use w, *a, &p}
            return app.call(env)
          end
        else
          return [
            STATUS__NOT_IMPLEMENTED,
            {"Content-Type" => "text/plain"},
            ["Resource found but it can be accessed only through %s" % route.keys.join(", ")]
          ]
        end
      end
    end
    [
      STATUS__NOT_FOUND,
      {"Content-Type" => "text/plain", "X-Cascade" => "pass"},
      ["Not Found: #{env[ENV__PATH_INFO]}"]
    ]
  end

  def sorted_routes
    @sorted_routes ||= Hash[@routes.sort {|a,b| b.first.source.size <=> a.first.source.size}]
  end

  def path_ok? path
    # comparing fixnums are much faster than comparing strings
    path.hash == (@empty_string_hash  ||= ''.hash ) || # replaces path.empty?
      path[0..0].hash == (@slash_hash ||= '/'.hash)    # replaces path =~ /\A\//
      # using path[0..0] instead of just path[0] for compatibility with ruby 1.8
  end

  def mount_controller controller, *roots, &setup
    return if @mounted_controllers.include?(controller)

    root = roots.shift
    if root || base_url.size > 0
      controller.remap!(base_url + root.to_s, *roots)
    end

    setup && controller.class_exec(&setup)
    @global_setup && controller.class_exec(&@global_setup)
    controller.mount! self
    @routes.update controller.routes

    @mounted_controllers << controller
  end

  def discover_controllers namespace = nil
    controllers = ::ObjectSpace.each_object(::Class).
      select { |c| is_app?(c) }.reject { |c| [E].include? c }
    return controllers unless namespace

    namespace.is_a?(Regexp) ?
      controllers.select { |c| c.name =~ namespace } :
      controllers.select { |c| [c.name, c.name.split('::').last].include? namespace.to_s }
  end

  def extract_controllers namespace
    return ([namespace] + namespace.constants.map { |c| namespace.const_get(c) }).
      select { |c| is_app? c } if [Class, Module].include?(namespace.class)

    discover_controllers namespace
  end
end
