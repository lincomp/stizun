class SupplyItem < ActiveRecord::Base
  include ThinkingSphinx::Scopes

  #validates_presence_of :stock, :weight, :name
  #validates_numericality_of :stock, :weight, :purchase_price

  #validates_presence_of :ean_code, :if => lambda { self.manufacturer_product_code.blank? }

  belongs_to :supplier
  has_one :product


  before_create :set_status_to_available_if_nil
  before_save :normalize_stock, :handle_supply_item_deletion, :handle_supply_item_reactivation
  after_save :generate_categories, :auto_create_products
  after_create :auto_create_products
  after_save ThinkingSphinx::RealTime.callback_for(:supply_item)

  def self.per_page
    return 100
  end

  # === Constants and associated methods

  AVAILABLE = 1
  DELETED = 2

  STATUS_HASH = { AVAILABLE => 'stizun.constants.available',
                  DELETED   => 'stizun.constants.deleted'}

  # Workflow status is there to help store managers find out which supply items they've already considered
  # for importing into the shop and which ones are not useful to have around.
  # New: The Item was newly imported (the default)
  # Checked: A store manager has looked at this supply item already (to differentiate this from new)
  # Rejected: The store manager thinks this supply item is pointless, it will never make it into a product

  FRESH = 1
  CHECKED = 2
  REJECTED = 3

  WORKFLOW_STATUS_HASH = { FRESH => 'stizun.constants.fresh',
                           CHECKED => 'stizun.constants.checked',
                           REJECTED => 'stizun.constants.rejected' }

  def self.status_to_human(status)
    # Gotta call I18n.t like this because it doesn't have the correct
    # locale set outside this definition on _some_ installations, not all.
    # Possibly broken in Rails.
    if status.blank?
      return "not set"
    else
      return I18n.t(STATUS_HASH[status])
    end
  end

  def self.status_hash_for_select
    hash = []
    STATUS_HASH.each do |key,value|
      hash << [I18n.t(value), key]
    end
    return hash
  end

  def status_human
    return SupplyItem::status_to_human(self.status_constant)
  end

  def workflow_status_to_human
    if self.workflow_status_constant.blank?
      return "not set"
    else
      return I18n.t(WORKFLOW_STATUS_HASH[self.workflow_status_constant])
    end
  end

  # === Named scopes

  scope :available, -> { where(:status_constant => SupplyItem::AVAILABLE) }
  scope :deleted, -> { where(:status_constant => SupplyItem::DELETED) }
  scope :unavailable, -> { where([ "status_constant <> #{SupplyItem::AVAILABLE}"]) }

  scope :fresh, -> { where(:workflow_status_constant => SupplyItem::FRESH) }
  scope :rejected, -> { where(:workflow_status_constant => SupplyItem::REJECTED) }
  scope :checked, -> { where(:workflow_status_constant => SupplyItem::CHECKED) }

  scope :in_stock, -> { where('stock > 0') }

  scope :distinct_categories, -> { select("DISTINCT(category_string)").order("category_string DESC")}

  # Sphinx scopes
  sphinx_scope(:sphinx_available_items) {
    {
    :conditions => { :status_constant => SupplyItem::AVAILABLE }
    }
  }

  def self.category_tree(supplier)
    all_categories = distinct_categories.where(:supplier_id => supplier).map(&:category_string)
    sub_categories = []
    all_categories.each do |category_string|
      categories = category_string.split(" :: ").each(&:strip)
      categories.inject([]) do |string, cat|
        string << cat
        sub_categories << string.join(" :: ")
        string
      end
    end
    (all_categories + sub_categories).uniq.sort
  end

  def to_s
    "#{supplier_product_code} #{name}"
  end

  # This should really be done as a default on the database instead
  def set_status_to_available_if_nil
    self.status_constant = SupplyItem::AVAILABLE if self.status_constant == nil
  end

  def component_of
    product_sets = ProductSet.where(:component_id => self.id)
    product_sets.collect(&:product).uniq.compact
  end

  def retrieve_product_picture
    unless self.reload.product.blank? or self.image_url.blank?
      require_relative '../../lib/image_handler'
      image_path = ImageHandler.get_image_by_http(self.image_url, self.id)
      unless image_path.blank?
        prod = self.product

        pp = ProductPicture.new
        pp.file = File.open(image_path, "r")
        prod.product_pictures << pp
        if prod.save
          logger.info "Product picture attached to #{prod.to_s}"
          return true
        else
          logger.error "Couldn't attach product picture to #{prod.to_s}"
          logger.error "Error was: #{prod.errors.full_messages}"
          return false
        end
      end
    end
  end


  def retrieve_pdf
    unless self.product.blank? or self.pdf_url.blank?
      require_relative '../../lib/pdf_handler'
      pdf_path = PdfHandler.get_pdf_by_http(self.pdf_url, self.id)
      unless pdf_path.blank?
        att = Attachment.new
        att.file = File.open(pdf_path, "r")
        prod = self.product
        prod.attachments << att
        if prod.save
          logger.info "PDF attachment added to #{prod.to_s}"
          return true
        else
          logger.error "Couldn't attach PDF to #{prod.to_s}"
          logger.error "Error was: #{prod.errors.full_messages}"
          return false
        end
      end
    end
  end

  # This should really be done as a default on the database instead
  def normalize_stock
    self.stock = 0 if self.stock.nil?
  end

  # This is NOT enabled in the before filters further up in this code.
  # The reason is that it turned out not to be wise in all cases, since sometimes things that had
  # a stock of -214 miraculously came back into the supplier's stock, and then we didn't have the matching 
  # products anymore, thus never received price updates again and didn't actually sell any of the products.
  def delete_if_stock_too_low
    self.status_constant = SupplyItem::DELETED if self.stock < 0
  end

  def handle_supply_item_deletion
    if self.status_constant_was == SupplyItem::AVAILABLE and \
       self.status_constant == SupplyItem::DELETED
      # If this supply item was used as a product component, remove it from the
      # product, disable the product.
      affected_products = self.component_of
      affected_products.each do |ap|
        ap.disable_product
      end

      # Disable the product because its supply item has become deleted
      # This is different from the above, above we handle situations involving
      # _components_ and componentized products
      unless self.product.blank?
        self.product.disable_product
      end
    end
  end

  def handle_supply_item_reactivation
    if self.status_constant_was == SupplyItem::DELETED and \
       self.status_constant == SupplyItem::AVAILABLE

      # Enable the product because its supply item has become available again.
      unless self.product.blank?
        self.product.enable_product
      end
    end
  end


  def generate_categories
    categories = unless self.category01.blank? && self.category02.blank? && self.category03.blank?
      "#{self.supplier.name} :: #{self.category01} :: #{self.category02} :: #{self.category03}"
    else
      ":: No Category ::"
    end
    update_column(:category_string, categories)
  end

  def self.expire_category_tree_cache(supplier)
    Rails.cache.delete("supplier_#{supplier.id}_category_tree")
  end

  def get_description
    description = nil
    unless self.supplier.nil? or self.supplier.utility_class_name.blank? or self.description_url.blank?
      lib_path = Rails.root + "lib/#{self.supplier.utility_class_name.underscore}" 
      if File.exists?("#{lib_path}.rb")
        require lib_path
        description = self.supplier.utility_class_name.constantize.get_product_description_from_url(self.description_url)
      end
    end
    return description
  end

  def auto_create_products
    unless self.product
      target_categories = CategoryDispatcher.dispatch([category01, category02, category03])
      if target_categories
        p = Product.new_from_supply_item(self)
        p.categories = p.categories | target_categories
        if p.save
          logger.info("SupplyItem/CategoryDispatcher: Auto-created product #{p.to_s} from #{self.to_s} due to category dispatcher.")
        end
      end
    else
      logger.info("SupplyItem/CategoryDispatcher: Not auto-creating products for #{self.to_s} because it already has a product.")
    end
  end
end
