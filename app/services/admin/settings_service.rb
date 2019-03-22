class Admin::SettingsService
  attr_reader :community, :params

  def initialize(community:, params:)
    @params = params
    @community = community
  end

  def update
    update_payment_settings
    update_configuration
    community.update_attributes(settings_params)
  end

  private

  def settings_params
    params.require(:community).permit(
      :join_with_invite_only,
      :users_can_invite_new_users,
      :private,
      :require_verification_to_post_listings,
      :show_category_in_listing_list,
      :show_listing_publishing_date,
      :listing_comments_in_use,
      :automatic_confirmation_after_days,
      :automatic_newsletters,
      :default_min_days_between_community_updates,
      :email_admins_about_new_members,
      :pre_approved_listings
    )
  end

  def update_payment_settings
    automatic_confirmation_after_days = params[:community][:automatic_confirmation_after_days]
    return unless automatic_confirmation_after_days

    paypal_settings = PaymentSettings.paypal.find_by(community_id: community.id)
    paypal_settings&.update_column(:confirmation_after_days, automatic_confirmation_after_days.to_i)

    stripe_settings = PaymentSettings.stripe.find_by(community_id: community.id)
    stripe_settings&.update_column(:confirmation_after_days, automatic_confirmation_after_days.to_i)
  end

  def update_configuration
    if FeatureFlagHelper.location_search_available
      community.configuration.update(
        main_search: params[:main_search],
        distance_unit: params[:distance_unit],
        limit_search_distance: params[:limit_distance].present?)
    end
  end
end
