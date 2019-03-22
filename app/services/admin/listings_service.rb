class Admin::ListingsService
  attr_reader :community, :params, :person

  def initialize(community:, params:, person: nil)
    @params = params
    @community = community
    @person = person
  end

  def listing
    @listing ||= resource_scope.find(params[:id])
  end

  def update
    case params[:listing][:state]
    when Listing::APPROVED
      approve
    when Listing::APPROVAL_REJECTED
      reject
    end
  end

  def approve
    listing.update_column(:state, Listing::APPROVED) # rubocop:disable Rails/SkipsModelValidations
    send_listing_approved(listing)
  end

  def reject
    listing.update_column(:state, Listing::APPROVAL_REJECTED) # rubocop:disable Rails/SkipsModelValidations
    send_listing_rejected(listing)
  end

  def update_by_author_params(update_listing)
    if community.pre_approved_listings? && !person.has_admin_rights?(community)
      if update_listing.approved? || update_listing.approval_rejected?
        {state: Listing::APPROVAL_PENDING}
      else
        {}
      end
    else
      {state: Listing::APPROVED}
    end
  end

  def update_by_author_successful(update_listing)
    if update_listing.approval_pending?
      community.admins.each do |admin|
        send_listing_submited_for_review(update_listing, admin)
      end
    end
  end

  def create_state(new_listing)
    if FeatureFlagHelper.feature_enabled?(:approve_listings) &&
       community.pre_approved_listings?
      unless person.has_admin_rights?(community)
        new_listing.state = Listing::APPROVAL_PENDING
      end
    end
  end

  def create_successful(new_listing)
    if new_listing.approval_pending?
      community.admins.each do |admin|
        send_listing_submited_for_review(new_listing, admin)
      end
    end
  end

  private

  def resource_scope
    community.listings
  end

  def send_listing_submited_for_review(listing, recipient)
    PersonMailer.listing_submited_for_review(listing, recipient).deliver_now
  end
  handle_asynchronously :send_listing_submited_for_review

  def send_listing_approved(listing)
    PersonMailer.listing_approved(listing).deliver_now
  end
  handle_asynchronously :send_listing_approved

  def send_listing_rejected(listing)
    PersonMailer.listing_rejected(listing).deliver_now
  end
  handle_asynchronously :send_listing_rejected
end
