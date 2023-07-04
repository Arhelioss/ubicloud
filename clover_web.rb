# frozen_string_literal: true

require_relative "./routes/base"

require "tilt/sass"

class CloverWeb < Roda
  Unreloader.require "./routes/base.rb"

  include CloverBase

  opts[:check_dynamic_arity] = false
  opts[:check_arity] = :warn

  plugin :default_headers,
    "Content-Type" => "text/html",
    # 'Strict-Transport-Security'=>'max-age=16070400;', # Uncomment if only allowing https:// access
    "X-Frame-Options" => "deny",
    "X-Content-Type-Options" => "nosniff",
    "X-XSS-Protection" => "1; mode=block"

  plugin :content_security_policy do |csp|
    csp.default_src :none
    csp.style_src :self
    csp.img_src :self
    csp.form_action :self
    csp.script_src :self, "https://cdn.jsdelivr.net"
    csp.connect_src :self
    csp.base_uri :none
    csp.frame_ancestors :none
  end

  plugin :route_csrf
  plugin :disallow_file_uploads
  plugin :flash
  plugin :assets, js: "app.js", css: "app.css", css_opts: {style: :compressed, cache: false}, timestamp_paths: true
  plugin :render, escape: true, layout: "./layouts/app"
  plugin :public
  plugin :Integer_matcher_max
  plugin :typecast_params_sized_integers, sizes: [64], default_size: 64
  plugin :hash_branch_view_subdir

  plugin :not_found do
    @error = {
      code: 404,
      title: "Resource not found",
      message: "Sorry, we couldn’t find the resource you’re looking for."
    }

    view "/error"
  end

  if Config.development?
    # :nocov:
    plugin :exception_page
    class RodaRequest
      def assets
        exception_page_assets
        super
      end
    end
    # :nocov:
  end

  plugin :error_handler do |e|
    @error = parse_error(e)

    case e
    when Sequel::ValidationFailed
      flash["error"] = @error[:message]
      return redirect_back_with_inputs
    when Validation::ValidationFailed
      flash["errors"] = (flash["errors"] || {}).merge(@error[:details])
      return redirect_back_with_inputs
    end

    # :nocov:
    next exception_page(e, assets: true) if Config.development? && @error[:code] == 500
    # :nocov:

    view "/error"
  end

  plugin :sessions,
    key: "_Clover.session",
    cookie_options: {secure: !(Config.development? || Config.test?)},
    secret: Config.clover_session_secret

  autoload_routes("web")

  plugin :rodauth do
    enable :argon2, :change_login, :change_password, :close_account, :create_account,
      :lockout, :login, :logout, :remember, :reset_password,
      :otp, :recovery_codes, :sms_codes,
      :disallow_password_reuse, :password_grace_period, :active_sessions,
      :verify_login_change, :change_password_notify, :confirm_password
    title_instance_variable :@page_title

    # :nocov:
    unless Config.development?
      enable :disallow_common_passwords, :verify_account

      email_from Config.mail_from

      verify_account_view { view "auth/verify_account", "Verify Account" }
      resend_verify_account_view { view "auth/verify_account_resend", "Resend Verification" }
      verify_account_email_sent_redirect { login_route }
      verify_account_email_recently_sent_redirect { login_route }
      verify_account_set_password? false
    end
    # :nocov:

    hmac_secret Config.clover_session_secret

    login_view { view "auth/login", "Login" }
    login_redirect "/dashboard"
    login_return_to_requested_location? true
    two_factor_auth_return_to_requested_location? true
    already_logged_in { redirect login_redirect }
    after_login { remember_login if request.params["remember-me"] == "on" }

    create_account_view { view "auth/create_account", "Create Account" }
    create_account_redirect { login_route }
    create_account_set_password? true
    after_create_account do
      current_user = Account[account_id]
      current_user.create_project_with_default_policy("#{current_user.username}-default-project")
    end

    reset_password_view { view "auth/reset_password", "Request Password" }
    reset_password_request_view { view "auth/reset_password_request", "Request Password Reset" }
    reset_password_redirect { login_route }
    reset_password_email_sent_redirect { login_route }
    reset_password_email_recently_sent_redirect { reset_password_request_route }

    change_password_redirect "/settings/change-password"
    change_password_route "settings/change-password"
    change_password_view { view "settings/change_password", "Settings" }

    change_login_redirect "/settings/change-login"
    change_login_route "settings/change-login"
    change_login_view { view "settings/change_login", "Settings" }

    close_account_redirect "/login"
    close_account_route "settings/close-account"
    close_account_view { view "settings/close_account", "Settings" }

    # YYY: Should password secret and session secret be the same? Are
    # there rotation issues? See also:
    #
    # https://github.com/jeremyevans/rodauth/commit/6cbf61090a355a20ab92e3420d5e17ec702f3328
    # https://github.com/jeremyevans/rodauth/commit/d8568a325749c643c9a5c9d6d780e287f8c59c31
    argon2_secret { Config.clover_session_secret }
    require_bcrypt? false
  end

  def redirect_back_with_inputs
    flash["old"] = request.params
    request.redirect env["HTTP_REFERER"]
  end

  hash_branch("dashboard") do |r|
    view "/dashboard"
  end

  route do |r|
    r.public
    r.assets

    check_csrf!

    rodauth.load_memory
    rodauth.check_active_session
    r.rodauth
    r.root do
      r.redirect rodauth.login_route
    end
    rodauth.require_authentication

    r.hash_branches("")
  end
end