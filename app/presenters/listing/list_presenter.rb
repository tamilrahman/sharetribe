class Listing::ListPresenter
  include Rails.application.routes.url_helpers

  attr_reader :community, :author, :params, :admin_mode

  def initialize(community, author, params, admin_mode)
    @author = author
    @community = community
    @params = params
    @admin_mode = admin_mode
  end

  def listings
    @listings ||= resource_scope.order("#{sort_column} #{sort_direction}").paginate(:page => params[:page], :per_page => 30)
  end

  def reset_search_path
    if admin_mode
      admin_community_listings_path(community, locale: I18n.locale)
    else
      listings_person_settings_path(author.username, sort: "updated", locale: I18n.locale)
    end
  end

  def statuses
    return @statuses if defined?(@statuses)
    result = ['open', 'closed', 'expired']
    result += [Listing::APPROVAL_PENDING, Listing::APPROVAL_REJECTED] if community.pre_approved_listings
    @statuses = result
  end

  def listing_status(listing)
    if listing.approval_pending? || listing.approval_rejected?
      listing.state
    elsif listing.valid_until && listing.valid_until < DateTime.current
      'expired'
    else
      listing.open? ? 'open' : 'closed'
    end
  end

  def listing_wait_for_approval?(listing)
    listing.approval_pending?
  end

  def show_approval_link?(listing)
    FeatureFlagHelper.feature_enabled?(:approve_listings) && admin_mode && listing_wait_for_approval?(listing)
  end

  private

  def resource_scope
    scope = community.listings.exist.includes(:author, :category)

    unless admin_mode
      scope = scope.where(author: author)
    end

    if params[:q].present?
      scope = scope.search_title_author_category(params[:q])
    end

    if params[:status].present?
      statuses = []
      statuses.push(Listing.status_open) if params[:status].include?('open')
      statuses.push(Listing.status_closed) if params[:status].include?('closed')
      statuses.push(Listing.status_expired) if params[:status].include?('expired')
      statuses.push(Listing.approval_pending) if params[:status].include?(Listing::APPROVAL_PENDING)
      statuses.push(Listing.approval_rejected) if params[:status].include?(Listing::APPROVAL_REJECTED)
      if statuses.size > 1
        status_scope = statuses.slice!(0)
        statuses.map{|x| status_scope = status_scope.or(x)}
        scope = scope.merge(status_scope)
      else
        scope = scope.merge(statuses.first)
      end
    end

    scope
  end

  def sort_column
    case params[:sort]
    when 'started'
      'listings.created_at'
    when 'updated', nil
      'listings.updated_at'
    end
  end

  def sort_direction
    params[:direction] == 'asc' ? 'asc' : 'desc'
  end
end
