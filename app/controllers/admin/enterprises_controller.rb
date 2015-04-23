module Admin
  class EnterprisesController < ResourceController
    before_filter :load_enterprise_set, :only => :index
    before_filter :load_countries, :except => [:index, :set_sells, :check_permalink]
    before_filter :load_methods_and_fees, :only => [:new, :edit, :update, :create]
    before_filter :load_taxons, :only => [:new, :edit, :update, :create]
    before_filter :check_can_change_sells, only: :update
    before_filter :check_can_change_bulk_sells, only: :bulk_update
    before_filter :override_owner, only: :create
    before_filter :override_sells, only: :create
    before_filter :check_can_change_owner, only: :update
    before_filter :check_can_change_bulk_owner, only: :bulk_update
    before_filter :check_can_change_managers, only: :update
    before_filter :strip_new_properties, only: [:create, :update]
    before_filter :load_properties, only: [:edit, :update]
    before_filter :setup_property, only: [:edit]


    helper 'spree/products'
    include ActionView::Helpers::TextHelper
    include OrderCyclesHelper

    def set_sells
      enterprise = Enterprise.find_by_permalink(params[:id]) || Enterprise.find(params[:id])
      attributes = { sells: params[:sells] }
      attributes[:producer_profile_only] = params[:sells] == "none" && !!params[:producer_profile_only]
      attributes[:shop_trial_start_date] = Time.now if params[:sells] == "own"

      if %w(none own).include?(params[:sells])
        if params[:sells] == 'own' && enterprise.shop_trial_start_date
          expiry = enterprise.shop_trial_start_date + Enterprise::SHOP_TRIAL_LENGTH.days
          if Time.now > expiry
            flash[:error] = "Sorry, but you've already had a trial. Expired on: #{expiry.strftime('%Y-%m-%d')}"
          else
            attributes.delete :shop_trial_start_date
            enterprise.update_attributes(attributes)
            flash[:notice] = "Welcome back! Your trial expires on: #{expiry.strftime('%Y-%m-%d')}"
          end
        elsif enterprise.update_attributes(attributes)
          flash[:success] = "Congratulations! Registration for #{enterprise.name} is complete!"
        end
      else
        flash[:error] = "Unauthorised"
      end
      redirect_to admin_path
    end

    def bulk_update
      @enterprise_set = EnterpriseSet.new(collection, params[:enterprise_set])
      touched_enterprises = @enterprise_set.collection.select(&:changed?)
      if @enterprise_set.save
        flash[:success] = "Enterprises updated successfully"

        # 18-3-2015: It seems that the form for this action sometimes loads bogus values for
        # the 'sells' field, and submitting that form results in a bunch of enterprises with
        # values that have mysteriously changed. This statement is here to help debug that
        # issue, and should be removed (along with its display in index.html.haml) when the
        # issue has been resolved.
        flash[:action] = "Updated #{pluralize(touched_enterprises.count, 'enterprise')}: #{touched_enterprises.map(&:name).join(', ')}"

        redirect_to main_app.admin_enterprises_path
      else
        @enterprise_set.collection.select! { |e| touched_enterprises.include? e }
        flash[:error] = 'Update failed'
        render :index
      end
    end

    def for_order_cycle
      respond_to do |format|
        format.json do
          render json: ActiveModel::ArraySerializer.new( @collection,
            each_serializer: Api::Admin::ForOrderCycle::EnterpriseSerializer, spree_current_user: spree_current_user
          ).to_json
        end
      end
    end

    protected

    def build_resource_with_address
      enterprise = build_resource_without_address
      enterprise.address = Spree::Address.new
      enterprise.address.country = Spree::Country.find_by_id(Spree::Config[:default_country_id])
      enterprise
    end
    alias_method_chain :build_resource, :address

    # Overriding method on Spree's resource controller,
    # so that resources are found using permalink
    def find_resource
      Enterprise.find_by_permalink(params[:id])
    end

    private

    def load_enterprise_set
      @enterprise_set = EnterpriseSet.new collection
    end

    def load_countries
      @countries = Spree::Country.order(:name)
    end

    def collection
      case action
      when :for_order_cycle
        order_cycle = OrderCycle.find_by_id(params[:order_cycle_id]) if params[:order_cycle_id]
        coordinator = Enterprise.find_by_id(params[:coordinator_id]) if params[:coordinator_id]
        order_cycle = OrderCycle.new(coordinator: coordinator) if order_cycle.nil? && coordinator.present?
        return OpenFoodNetwork::OrderCyclePermissions.new(spree_current_user, order_cycle).visible_enterprises
      else
        # TODO was ordered with is_distributor DESC as well, not sure why or how we want to sort this now
        OpenFoodNetwork::Permissions.new(spree_current_user).
          editable_enterprises.
          order('is_primary_producer ASC, name')
      end
    end

    def collection_actions
      [:index, :for_order_cycle, :bulk_update]
    end

    def load_methods_and_fees
      @payment_methods = Spree::PaymentMethod.managed_by(spree_current_user).sort_by!{ |pm| [(@enterprise.payment_methods.include? pm) ? 0 : 1, pm.name] }
      @shipping_methods = Spree::ShippingMethod.managed_by(spree_current_user).sort_by!{ |sm| [(@enterprise.shipping_methods.include? sm) ? 0 : 1, sm.name] }
      @enterprise_fees = EnterpriseFee.managed_by(spree_current_user).for_enterprise(@enterprise).order(:fee_type, :name).all
    end

    def load_taxons
      @taxons = Spree::Taxon.order(:name)
    end

    def check_can_change_bulk_sells
      unless spree_current_user.admin?
        params[:enterprise_set][:collection_attributes].each do |i, enterprise_params|
          enterprise_params.delete :sells
        end
      end
    end

    def check_can_change_sells
      params[:enterprise].delete :sells unless spree_current_user.admin?
    end

    def override_owner
      params[:enterprise][:owner_id] = spree_current_user.id unless spree_current_user.admin?
    end

    def override_sells
      unless spree_current_user.admin?
        has_hub = spree_current_user.owned_enterprises.is_hub.any?
        new_enterprise_is_producer = Enterprise.new(params[:enterprise]).is_primary_producer
        params[:enterprise][:sells] = (has_hub && !new_enterprise_is_producer) ? 'any' : 'none'
      end
    end

    def check_can_change_owner
      unless ( spree_current_user == @enterprise.owner ) || spree_current_user.admin?
        params[:enterprise].delete :owner_id
      end
    end

    def check_can_change_bulk_owner
      unless spree_current_user.admin?
        params[:enterprise_set][:collection_attributes].each do |i, enterprise_params|
          enterprise_params.delete :owner_id
        end
      end
    end

    def check_can_change_managers
      unless ( spree_current_user == @enterprise.owner ) || spree_current_user.admin?
        params[:enterprise].delete :user_ids
      end
    end

    def strip_new_properties
      unless spree_current_user.admin? || params[:enterprise][:producer_properties_attributes].nil?
        names = Spree::Property.pluck(:name)
        params[:enterprise][:producer_properties_attributes].each do |key, property|
          params[:enterprise][:producer_properties_attributes].delete key unless names.include? property[:property_name]
        end
      end
    end

    def load_properties
      @properties = Spree::Property.pluck(:name)
    end

    def setup_property
      @enterprise.producer_properties.build
    end

    # Overriding method on Spree's resource controller
    def location_after_save
      refered_from_edit = URI(request.referer).path == main_app.edit_admin_enterprise_path(@enterprise)
      if params[:enterprise].key?(:producer_properties_attributes) && !refered_from_edit
        main_app.admin_enterprises_path
      else
        main_app.edit_admin_enterprise_path(@enterprise)
      end
    end
  end
end
