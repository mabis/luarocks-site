-- User management actions not related to modules

lapis = require "lapis"
db = require "lapis.db"

import
  respond_to
  capture_errors
  assert_error
  yield_error
  from require "lapis.application"

import assert_valid from require "lapis.validate"
import trim_filter from require "lapis.util"

import
  ApiKeys
  Users
  Manifests
  ManifestModules
  from require "models"

import
  assert_csrf
  require_login
  ensure_https
  capture_errors_404
  assert_editable
  verify_return_to
  from require "helpers.app"

import load_module, load_manifest from require "helpers.loaders"
import paginated_modules from require "helpers.modules"

assert_table = (val) ->
  assert_error type(val) == "table", "malformed input, expecting table"
  val

validate_reset_token = =>
  if @params.token
    assert_valid @params, {
      { "id", is_integer: true }
    }

    @user = assert_error Users\find(@params.id), "invalid token"
    @user\get_data!
    assert_error @user.data.password_reset_token == @params.token, "invalid token"
    @token = @params.token
    true

class MoonRocksUser extends lapis.Application
  [user_profile: "/modules/:user"]: capture_errors_404 =>
    @user = assert_error Users\find(slug: @params.user), "invalid user"

    @title = "#{@user.username}'s Modules"
    paginated_modules @, @user, (mods) ->
      for mod in *mods
        mod.user = @user
      mods

    render: true

  [user_login: "/login"]: ensure_https respond_to {
    before: =>
      @title = "Login"

    GET: =>
      render: true

    POST: capture_errors =>
      assert_csrf @

      assert_valid @params, {
        { "username", exists: true }
        { "password", exists: true }
      }

      user = assert_error Users\login @params.username, @params.password
      user\write_session @

      redirect_to: verify_return_to(@params.return_to) or @url_for"index"
  }

  [user_register: "/register"]: ensure_https respond_to {
    before: =>
      @title = "Register Account"

    GET: =>
      render: true

    POST: capture_errors =>
      assert_csrf @
      assert_valid @params, {
        { "username", exists: true, min_length: 2, max_length: 25 }
        { "password", exists: true, min_length: 2 }
        { "password_repeat", equals: @params.password }
        { "email", exists: true, min_length: 3 }
      }

      {:username, :password, :email } = @params
      user = assert_error Users\create username, password, email

      user\write_session @
      redirect_to: verify_return_to(@params.return_to) or @url_for"index"
  }

  -- TODO: make this post
  [user_logout: "/logout"]: =>
    @session.user = false
    redirect_to: "/"

  [user_forgot_password: "/user/forgot_password"]: ensure_https respond_to {
    GET: capture_errors =>
      validate_reset_token @
      render: true

    POST: capture_errors =>
      assert_csrf @

      if validate_reset_token @
        assert_valid @params, {
          { "password", exists: true, min_length: 2 }
          { "password_repeat", equals: @params.password }
        }
        @user\update_password @params.password, @
        @user.data\update { password_reset_token: db.NULL }
        redirect_to: @url_for"index"
      else
        assert_valid @params, {
          { "email", exists: true, min_length: 3 }
        }

        user = assert_error Users\find([db.raw "lower(email)"]: @params.email\lower!),
          "don't know anyone with that email"

        token = user\generate_password_reset!

        reset_url = @build_url @url_for"user_forgot_password",
          query: "token=#{token}&id=#{user.id}"

        UserPasswordResetEmail = require "emails.user_password_reset"
        UserPasswordResetEmail\send @, user.email, { :user, :reset_url }

        redirect_to: @url_for"user_forgot_password" .. "?sent=true"
  }

  [user_settings: "/settings"]: ensure_https require_login respond_to {
    before: =>
      import GithubAccounts from require "models"

      @user = @current_user
      @user\get_data!
      @title = "User Settings"

      @github_accounts = @user\find_github_accounts!
      @api_keys = ApiKeys\select "where user_id = ?", @user.id

    GET: =>
      render: true

    POST: capture_errors =>
      assert_csrf @

      if passwords = @params.password
        assert_table passwords
        trim_filter passwords

        assert_valid passwords, {
          { "new_password", exists: true, min_length: 2 }
          { "new_password_repeat", equals: passwords.new_password }
        }

        assert_error @user\check_password(passwords.current_password),
          "Invalid old password"

        @user\update_password passwords.new_password, @

      redirect_to: @url_for"user_settings" .. "?password_reset=true"
  }

  [add_to_manifest: "/add-to-manifest/:user/:module"]: capture_errors_404 require_login respond_to {
    before: =>
      load_module @
      assert_editable @, @module

      @title = "Add Module To Manifest"

      already_in = { m.id, true for m in *@module\get_manifests! }
      @manifests = for m in *Manifests\select!
        continue if already_in[m.id]
        m

    GET: =>
      render: true

    POST: capture_errors =>
      assert_csrf @

      assert_valid @params, {
        { "manifest_id", is_integer: true }
      }

      manifest = assert_error Manifests\find(id: @params.manifest_id), "Invalid manifest id"

      unless manifest\allowed_to_add @current_user
        yield_error "Don't have permission to add to manifest"

      assert_error ManifestModules\create manifest, @module
      redirect_to: @url_for("module", @)
  }


  [remove_from_manifest: "/remove-from-manifest/:user/:module/:manifest"]: capture_errors_404 require_login respond_to {
    before: =>
      load_module @
      load_manifest @

      assert_editable @, @module

    GET: =>
      @title = "Remove Module From Manifest"

      assert_error ManifestModules\find({
        manifest_id: @manifest.id
        module_id: @module.id
      }), "Module is not in manifest"

      render: true

    POST: =>
      assert_csrf @

      ManifestModules\remove @manifest, @module
      redirect_to: @url_for("module", @)
  }

