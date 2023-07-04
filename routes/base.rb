# frozen_string_literal: true

module CloverBase
  def self.included(base)
    base.extend(ClassMethods)
    base.plugin :all_verbs
    base.plugin :request_headers

    logger = if ENV["RACK_ENV"] == "test"
      Class.new {
        def write(_)
        end
      }.new
    else
      # :nocov:
      $stderr
      # :nocov:
    end
    base.plugin :common_logger, logger

    # :nocov:
    case Config.mail_driver
    when :smtp
      ::Mail.defaults do
        delivery_method :smtp, {
          address: Config.smtp_hostname,
          port: Config.smtp_port,
          user_name: Config.smtp_user,
          password: Config.smtp_password,
          authentication: :plain,
          enable_starttls: Config.smtp_tls
        }
      end
    when :logger
      ::Mail.defaults do
        delivery_method :logger
      end
    when :test
      ::Mail.defaults do
        delivery_method :test
      end
    end
    # :nocov:
  end

  # Assign some HTTP response codes to common exceptions.
  def parse_error(e)
    case e
    when Sequel::ValidationFailed
      code = 400
      title = "Invalid request"
      message = e.to_s
    when Validation::ValidationFailed
      code = 400
      title = "Invalid request"
      message = "Failed validations"
      details = e.errors
    when Roda::RodaPlugins::RouteCsrf::InvalidToken
      code = 419
      title = "Invalid Security Token"
      message = "An invalid security token was submitted with this request, and this request could not be processed."
    when Authorization::Unauthorized
      code = 403
      title = "Forbidden"
      message = "Sorry, you don't have permission to continue with this request."
    else
      $stderr.print "#{e.class}: #{e.message}\n"
      warn e.backtrace

      code = 500
      title = "Unexcepted Error"
      message = "Sorry, we couldn’t process your request because of an unexpected error."
    end

    response.status = code

    {
      code: code,
      title: title,
      message: message,
      details: details
    }
  end

  def serialize(data, structure = :default)
    @serializer.new(structure).serialize(data)
  end

  module ClassMethods
    def autoload_routes(route)
      route_path = "routes/#{route}"
      if Config.production?
        # :nocov:
        Unreloader.require(route_path)
        # :nocov:
      else
        plugin :autoload_hash_branches
        Dir["#{route_path}/**/*.rb"].each do |full_path|
          parts = full_path.delete_prefix("#{route_path}/").split("/")
          namespaces = parts[0...-1]
          filename = parts.last
          if namespaces.empty?
            autoload_hash_branch(File.basename(filename, ".rb").tr("_", "-"), full_path)
          else
            autoload_hash_branch("#{namespaces.join("_")}_prefix".intern, File.basename(filename, ".rb").tr("_", "-"), full_path)
          end
        end
        Unreloader.autoload(route_path, delete_hook: proc { |f| hash_branch(File.basename(f, ".rb").tr("_", "-")) }) {}
      end
    end

    def freeze
      # :nocov:
      Sequel::Model.freeze_descendents unless Config.test?
      # :nocov:
      DB.freeze
      super
    end
  end
end