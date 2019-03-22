class PaymentSettingsController < ApplicationController
  before_action do |controller|
    controller.ensure_logged_in t("layouts.notifications.you_must_log_in_to_view_your_settings")
  end

  before_action :ensure_payments_enabled
  before_action :load_stripe_account
  skip_before_action :warn_about_missing_payment_info, only: [:update]

  def index
    render 'index', locals: index_view_locals
  end

  def create
    unless @stripe_enabled
      redirect_to action: :index
    end

    @extra_forms = {}

    stripe_create_account
    stripe_update_bank_account

    # If we can't create both account and link external bank account, ignore this partial record, and not store in our DB
    if @stripe_error && @just_created && @stripe_account_ready
      stripe_accounts_api.destroy(community_id: @current_community.id, person_id: @current_user.id)
      @stripe_account[:stripe_seller_id] = nil
      @stripe_account_ready = false
      render 'index', locals: index_view_locals
      return
    end

    warn_about_missing_payment_info
    render 'index', locals: index_view_locals
  end

  def update
    unless (@stripe_enabled && @stripe_account_ready)
      redirect_to action: :index
    end

    @extra_forms = {}

    stripe_update_account
    stripe_update_bank_account

    warn_about_missing_payment_info
    render 'index', locals: index_view_locals
  end

  private

  def ensure_payments_enabled
    @paypal_enabled = PaypalHelper.community_ready_for_payments?(@current_community.id)
    @stripe_enabled = StripeHelper.community_ready_for_payments?(@current_community.id)
    unless @paypal_enabled || @stripe_enabled
      flash[:warning] = t("stripe_accounts.admin_account_not_connected",
                            contact_admin_link: view_context.link_to(
                              t("stripe_accounts.contact_admin_link_text"),
                                new_user_feedback_path)).html_safe # rubocop:disable Rails/OutputSafety
      redirect_to person_settings_path
    end
  end

  def paypal_tx_settings
    Maybe(settings_api.get(community_id: @current_community.id, payment_gateway: :paypal, payment_process: :preauthorize))
    .select { |result| result[:success] }
    .map { |result| result[:data] }
    .or_else({})
  end

  def stripe_tx_settings
    Maybe(settings_api.get(community_id: @current_community.id, payment_gateway: :stripe, payment_process: :preauthorize))
    .select { |result| result[:success] }
    .map { |result| result[:data] }
    .or_else({})
  end

  def build_view_locals
    @selected_left_navi_link = "payments"

    community_currency = @current_community.currency
    payment_settings = @paypal_enabled ? paypal_tx_settings : stripe_tx_settings

    community_country_code = LocalizationUtils.valid_country_code(@current_community.country)

    need_verification = false
    if @stripe_account_ready && @api_seller_account
      if FeatureFlagHelper.feature_enabled?(:new_stripe_api)
        requirements = @api_seller_account.requirements
        need_verification = requirements.currently_due.any? && requirements.disabled_reason.present?
      else
        verification = @api_seller_account.verification
        need_verification = verification.fields_needed.present? && verification.due_by.present?
      end
    end

    {
      left_hand_navigation_links: settings_links_for(@current_user, @current_community),
      commission_from_seller: t("stripe_accounts.commission", commission: payment_settings[:commission_from_seller]),
      minimum_commission: Money.new(payment_settings[:minimum_transaction_fee_cents], community_currency),
      commission_type: payment_settings[:commission_type],
      currency: community_currency,
      stripe_enabled: @stripe_enabled,
      paypal_enabled: @paypal_enabled,
      seller_account: @api_seller_account,
      seller_needs_verification: need_verification,
      paypal_commission: paypal_tx_settings[:commission_from_seller]
    }
  end

  def stripe_index
    {
      stripe_account: @stripe_account,
      stripe_seller_account: @parsed_seller_account,
      available_countries: CountryI18nHelper.translate_list(StripeService::Store::StripeAccount::COUNTRIES),
      stripe_account_form: StripeAccountForm.new(@parsed_seller_account),
      stripe_bank_form: StripeBankForm.new(@parsed_seller_account),
      stripe_mode: stripe_api.charges_mode(@current_community.id),
      stripe_test_mode: stripe_api.test_mode?(@current_community.id)
    }
  end

  def paypal_index
    paypal_account = paypal_accounts_api.get(community_id: @current_community.id, person_id: @current_user.id).data || {}
    community_country_code = LocalizationUtils.valid_country_code(@current_community.country)

    {
      next_action: next_action(paypal_account[:state] || ""),
      paypal_account: paypal_account,
      order_permission_action: ask_order_permission_person_paypal_account_path(@current_user),
      billing_agreement_action: ask_billing_agreement_person_paypal_account_path(@current_user),
      paypal_fees_url: PaypalCountryHelper.fee_link(community_country_code),
      create_url: PaypalCountryHelper.create_paypal_account_url(community_country_code),
      upgrade_url: PaypalCountryHelper.upgrade_paypal_account_url(community_country_code),
      receive_funds_info_label_tr_key: PaypalCountryHelper.receive_funds_info_label_tr_key(community_country_code),
      receive_funds_info_tr_key: PaypalCountryHelper.receive_funds_info_tr_key(community_country_code)
    }
  end

  def stripe_api
    StripeService::API::Api.wrapper
  end

  def stripe_payments_api
    StripeService::API::Api.payments
  end

  def settings_api
    TransactionService::API::Api.settings
  end

  def stripe_accounts_api
    StripeService::API::Api.accounts
  end

  def paypal_accounts_api
    PaypalService::API::Api.accounts
  end

  def next_action(paypal_account_state)
    if paypal_account_state == :verified
      :none
    elsif paypal_account_state == :connected
      :ask_billing_agreement
    else
      :ask_order_permission
    end
  end

  def load_stripe_account
    @stripe_account = stripe_accounts_api.get(community_id: @current_community.id, person_id: @current_user.id).data || {}
    @stripe_account_ready = @stripe_account[:stripe_seller_id].present?
    if @stripe_account_ready
      @api_seller_account = stripe_api.get_seller_account(community: @current_community.id, account_id: @stripe_account[:stripe_seller_id])
      @parsed_seller_account = parse_stripe_seller_account(@api_seller_account)
    else
      @parsed_seller_account = {
        email: @current_user.confirmed_notification_emails.any? ? @current_user.confirmed_notification_email_addresses.first : @current_user.emails.first.try(:address),
        url: person_url(@current_user.username)
      }
    end
  end

  StripeAccountForm = FormUtils.define_form("StripeAccountForm",
        :first_name,
        :last_name,
        :first_name_kana,
        :last_name_kana,
        :first_name_kanji,
        :last_name_kanji,
        :address_country,
        :address_city,
        :address_line1,
        :address_postal_code,
        :address_state,
        :birth_date,
        :personal_id_number,
        :address_city,
        :address_line1,
        :address_postal_code,
        :address_state,
        :document,
        :ssn_last_4,
        :token,
        :gender,
        :phone_number,
        :address_kana_postal_code,
        :address_kana_state,
        :address_kana_city,
        :address_kana_town,
        :address_kana_line1,
        :address_kanji_postal_code,
        :address_kanji_state,
        :address_kanji_city,
        :address_kanji_town,
        :address_kanji_line1,
        :id_number,
        :phone,
        :email,
        :mcc,
        :url
        ).with_validations do
    validates_inclusion_of :address_country, in: StripeService::Store::StripeAccount::COUNTRIES
    validates_presence_of :address_country
    validates_presence_of :token
  end

  def stripe_create_account
    return if @stripe_account_ready

    stripe_account_form = parse_create_params(params[:stripe_account_form])
    @extra_forms[:stripe_account_form] = stripe_account_form
    if stripe_account_form.valid?
      account_attrs = stripe_account_form.to_hash
      account_attrs[:email] =  @current_user.confirmed_notification_email_addresses.first || @current_user.primary_email.try(:address)
      result = stripe_accounts_api.create(community_id: @current_community.id, person_id: @current_user.id, body: account_attrs)
      if result[:success]
        @just_created = true
        load_stripe_account
      else
        @stripe_error = true
        flash.now[:error] = result[:error_msg]
      end
    end
  end

  def parse_create_params(params)
    allowed_params = mask_puerto_rico_as_us_pr(params.permit(*StripeAccountForm.keys).dup)
    allowed_params[:birth_date] = params["birth_date(1i)"].present? ? parse_date(params) : nil
    StripeAccountForm.new(allowed_params)
  end

  def parse_date(params)
    Date.new params["birth_date(1i)"].to_i, params["birth_date(2i)"].to_i, params["birth_date(3i)"].to_i
  end

  StripeBankForm = FormUtils.define_form("StripeBankForm",
        :bank_country,
        :bank_currency,
        :bank_holder_name,
        :bank_account_number,
        :bank_routing_number,
        :bank_routing_1,
        :bank_routing_2,
        :bank_account_number_common
        ).with_validations do
    validates_presence_of :bank_country,
        :bank_currency,
        :bank_holder_name,
        :bank_account_number
    validates_inclusion_of :bank_country, in: StripeService::Store::StripeAccount::COUNTRIES
    validates_inclusion_of :bank_currency, in: StripeService::Store::StripeAccount::VALID_BANK_CURRENCIES
  end

  def stripe_update_bank_account
    bank_params = StripeParseBankParams.new(parsed_seller_account: @parsed_seller_account, params: params).parse
    bank_form = StripeBankForm.new(bank_params)
    @extra_forms[:stripe_bank_form] = bank_form
    return if !@stripe_account_ready || params[:stripe_bank_form].blank?

    if bank_form.valid? && bank_form.bank_account_number !~ /\*/
      result = stripe_accounts_api.create_bank_account(community_id: @current_community.id, person_id: @current_user.id, body: bank_form.to_hash)
      if result[:success]
        load_stripe_account
      else
        @stripe_error = true
        flash.now[:error] = result[:error_msg]
        @parsed_seller_account[:bank_number_info] = (params[:stripe_bank_form].try(:[], :bank_account_number_common) ||
                                                     params[:stripe_bank_form].try(:[], :bank_account_number))
      end
    else
      flash.now[:error] = bank_form.errors.messages.flatten.join(' ')
    end
  end

  class StripeParseBankParams
    attr_reader :bank_country, :bank_currency, :form_params, :parsed_seller_account
    def initialize(parsed_seller_account:, params:)
      @parsed_seller_account = parsed_seller_account
      @bank_country = parsed_seller_account[:address_country]
      if @bank_country == 'PR'
        @bank_country = 'US'
      end
      @bank_currency = TransactionService::AvailableCurrencies::COUNTRY_CURRENCIES[@bank_country]
      @form_params = params[:stripe_bank_form]
    end

    def parse
      result = {
        bank_country: bank_country,
        bank_currency: bank_currency,
        bank_holder_name: parse_holder_name
      }
      if form_params.present?
        result.merge!({
          bank_account_number: parse_bank_account_number,
          bank_routing_number: parse_bank_routing_number,
          bank_routing_1: form_params[:bank_routing_1],
          bank_routing_2: form_params[:bank_routing_2],
        })
      end
      result
    end

    def parse_bank_routing_number
      if bank_country == 'NZ'
        bank_number, bank_branch, = form_params[:bank_account_number_common].split('-')
        "#{bank_number}#{bank_branch}"
      elsif bank_country == 'JP'
        [form_params[:bank_routing_1], form_params[:bank_routing_2]].join('')
      elsif form_params[:bank_routing_1].present?
        [form_params[:bank_routing_1], form_params[:bank_routing_2]].join("-")
      else
        form_params[:bank_routing_number]
      end
    end

    def parse_bank_account_number
      if bank_country == 'NZ'
        _, _, account, sufix = form_params[:bank_account_number_common].split('-')
        "#{account}#{sufix}"
      else
        form_params[:bank_account_number]
      end
    end

    def parse_holder_name
      if bank_country == 'JP'
        [parsed_seller_account[:first_name_kana], parsed_seller_account[:last_name_kana]].join(" ")
      else
        [parsed_seller_account[:first_name], parsed_seller_account[:last_name]].join(" ")
      end
    end
  end

  def stripe_update_account
    return unless @stripe_account_ready

    account_params = params.require(:stripe_account_form).dup
    address_attrs = account_params.permit(
      :first_name, :last_name, 'birth_date(1i)', 'birth_date(2i)', 'birth_date(3i)',
      :address_line1, :address_city, :address_state, :address_postal_code,
      :document, :personal_id_number, :token, :first_name_kana, :last_name_kana,
      :first_name_kanji, :last_name_kanji, :gender, :phone_number,
      :address_kana_postal_code, :address_kana_state, :address_kana_city,
      :address_kana_town, :address_kana_line1, :address_kanji_postal_code,
      :address_kanji_state, :address_kanji_city, :address_kanji_town,
      :address_kanji_line1, :address_country, :id_number, :phone, :email, :mcc,
      :url
    )
    address_attrs[:birth_date] = account_params['birth_date(1i)'].present? ? parse_date(account_params) : nil
    address_attrs = mask_puerto_rico_as_us_pr(address_attrs)
    @extra_forms[:stripe_account_form] = StripeAccountForm.new(address_attrs)

    result = stripe_accounts_api.update_account(community_id: @current_community.id, person_id: @current_user.id, attrs: address_attrs)
    if result[:success]
      load_stripe_account
    else
      flash.now[:error] = result[:error_msg]
    end
  end

  def parse_stripe_seller_account(account)
    bank_record = account.external_accounts.select{|x| x["default_for_currency"] }.first || {}
    bank_number = if bank_record.present?
      [bank_record["country"], bank_record["bank_name"], bank_record["currency"], "****#{bank_record['last4']}"].join(", ").upcase
    end
    entity = if FeatureFlagHelper.feature_enabled?(:new_stripe_api)
               account.individual
             else
               account.legal_entity
             end
    dob = entity.dob
    result = {
      first_name: entity.first_name,
      last_name: entity.last_name,
      birth_date: Date.new(dob[:year], dob[:month], dob[:day]),

      bank_number_info: bank_number,
      bank_currency: bank_record ? bank_record["currency"] : nil,
      bank_routing_number: bank_record ? bank_record[:routing_number] : nil
    }
    if FeatureFlagHelper.feature_enabled?(:new_stripe_api)
      result.merge!({
        email: entity[:email],
        phone: entity[:phone],
        mcc: account.try(:business_profile).try(:[], :mcc),
        url: account.try(:business_profile).try(:[], :url),
      })
    end

    if entity.respond_to?(:address)
      result.merge!({
        address_city: entity.address.city,
        address_state: entity.address.state,
        address_country: entity.address.country,
        address_line1: entity.address.line1,
        address_postal_code: entity.address.postal_code,
      })
    elsif entity.respond_to?(:address_kana) # supposed to be Japan
      result.merge!({
        address_country: entity.address_kana.country,
        first_name_kana: entity.first_name_kana,
        first_name_kanji: entity.first_name_kanji,
        gender: entity.gender,
        last_name_kana: entity.last_name_kana,
        last_name_kanji: entity.last_name_kanji,
        phone_number: entity[:phone_number],
        address_kana_postal_code: entity.address_kana.postal_code,
        address_kana_state: entity.address_kana.state,
        address_kana_city: entity.address_kana.city,
        address_kana_town: entity.address_kana.town,
        address_kana_line1: entity.address_kana.line1,
        address_kanji_postal_code: entity.address_kanji.postal_code,
        address_kanji_state: entity.address_kanji.state,
        address_kanji_city: entity.address_kanji.city,
        address_kanji_town: entity.address_kanji.town,
        address_kanji_line1: entity.address_kanji.line1,
        phone: entity[:phone],
      })
    end
    mask_us_pr_as_puerto_rico(result)
  end

  def index_view_locals
    more_locals = {}
    @extra_forms ||= {}

    if @stripe_enabled
      more_locals.merge!(stripe_index)
    end

    if @paypal_enabled
      more_locals.merge!(paypal_index)
    end

    build_view_locals.merge(more_locals).merge(@extra_forms)
  end

  def mask_puerto_rico_as_us_pr(params)
    if params[:address_country] == 'PR'
      params[:address_country] = 'US'
      params[:address_state] = 'PR'
    end
    params
  end

  def mask_us_pr_as_puerto_rico(params)
    if params[:address_country] == 'US' && params[:address_state] == 'PR'
      params[:address_country] = 'PR'
    end
    params
  end
end
