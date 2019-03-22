class Admin::Communities::MembershipService
  attr_reader :community, :params, :current_user

  PER_PAGE = 50

  def initialize(community:, params:, current_user:)
    @params = params
    @community = community
    @current_user = current_user
  end

  def memberships
    @memberships ||= filtered_scope.not_deleted_user
                                   .paginate(page: params[:page], per_page: PER_PAGE)
                                   .order("#{sort_column} #{sort_direction}")
  end

  def memberships_csv
    Enumerator.new do |yielder|
      generate_csv_for(yielder)
    end
  end

  def membership
    @membership ||= resource_scope.find_by(id: params[:id])
  end

  def membership_current_user?
    membership.person == current_user
  end

  def ban
    membership.update_attributes(status: "banned")
    membership.update_attributes(admin: 0) if membership.admin == 1
    community.close_listings_by_author(membership.person)
    membership
  end

  def unban
    membership.update_attributes(status: "accepted")
    membership
  end

  def removes_itself?
    ids = params[:remove_admin] || []
    ids.include?(current_user.id) && current_user.is_marketplace_admin?(community)
  end

  def promote_admin
    # rubocop:disable Rails/SkipsModelValidations
    resource_scope.where(person_id: params[:add_admin]).update_all("admin = 1")
    resource_scope.where(person_id: params[:remove_admin]).update_all("admin = 0")
    # rubocop:enable Rails/SkipsModelValidations
  end

  def posting_allowed
    # rubocop:disable Rails/SkipsModelValidations
    resource_scope.where(person_id: params[:allowed_to_post]).update_all("can_post_listings = 1")
    resource_scope.where(person_id: params[:disallowed_to_post]).update_all("can_post_listings = 0")
    # rubocop:enable Rails/SkipsModelValidations
  end

  def resend_confirmation
    email_to_confirm = membership.person.latest_pending_email_address(community)
    to_confirm = Email.find_by_address_and_community_id(email_to_confirm, community.id)
    Email.send_confirmation(to_confirm, community)
  end

  private

  def all_memberships
    resource_scope.not_deleted_user.includes(person: [:emails, :location])
  end

  def generate_csv_for(yielder)
    # first line is column names
    header_row = %w{
      user_id
      first_name
      last_name
      display_name
      username
      phone_number
      address
      email_address
      email_address_confirmed
      joined_at
      status
      is_admin
      accept_emails_from_admin
      language
    }
    header_row.push("can_post_listings") if community.require_verification_to_post_listings
    header_row += community.person_custom_fields.map{|f| f.name}
    yielder << header_row.to_csv(force_quotes: true)
    all_memberships.find_each do |membership|
      user = membership.person
      unless user.blank?
        user_data = {
          id: user.id,
          first_name: user.given_name,
          last_name: user.family_name,
          display_name: user.display_name,
          username: user.username,
          phone_number: user.phone_number,
          address: user.location ? user.location.address : "",
          email_address: nil,
          email_address_confirmed: nil,
          joined_at: membership.created_at,
          status: membership.status,
          is_admin: membership.admin,
          accept_emails_from_admin: nil,
          language: user.locale
        }
        user_data[:can_post_listings] = membership.can_post_listings if community.require_verification_to_post_listings
        community.person_custom_fields.each do |field|
          field_value = user.custom_field_values.by_question(field).first
          user_data[field.name] = field_value.try(:display_value)
        end
        user.emails.each do |email|
          accept_emails_from_admin = user.preferences["email_from_admins"] && email.send_notifications
          data = user_data.clone
          data[:email_address] = email.address
          data[:email_address_confirmed] = !!email.confirmed_at
          data[:accept_emails_from_admin] = !!accept_emails_from_admin
          yielder << data.values.to_csv(force_quotes: true)
        end
      end
    end
  end

  def sort_column
    case params[:sort]
    when "name"
      "people.given_name"
    when "display_name"
      "people.display_name"
    when "email"
      "emails.address"
    when "join_date"
      "created_at"
    when "posting_allowed"
      "can_post_listings"
    else
      "created_at"
    end
  end

  def sort_direction
    if params[:direction] == "asc"
      "asc"
    else
      "desc" #default
    end
  end

  def resource_scope
    community.community_memberships
  end

  def filtered_scope
    scope = resource_scope.includes(person: :emails)
    if params[:q].present?
      person_ids = Person
        .search_name_or_email(community.id, "%#{params[:q]}%")
        .select('people.id')

      scope = scope.where(person_id: person_ids)
    end
    if params[:status].present? && params[:status].is_a?(Array)
      statuses = []
      statuses.push(CommunityMembership.admin) if params[:status].include?('admin')
      statuses.push(CommunityMembership.banned) if params[:status].include?(CommunityMembership::BANNED)
      statuses.push(CommunityMembership.posting_allowed) if params[:status].include?('posting_allowed')
      statuses.push(CommunityMembership.accepted) if params[:status].include?(CommunityMembership::ACCEPTED)
      statuses.push(CommunityMembership.pending_email_confirmation) if params[:status].include?('unconfirmed')
      statuses.push(CommunityMembership.pending_consent) if params[:status].include?('pending')
      if statuses.size > 1
        status_scope = statuses.slice!(0)
        statuses.map{|x| status_scope = status_scope.or(x)}
        scope = scope.merge(status_scope)
      elsif statuses.size == 1
        scope = scope.merge(statuses.first)
      end
    end
    scope
  end
end
