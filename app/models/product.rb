class Product < ActiveRecord::Base
  include ThinkingSphinx::Scopes

  validates_uniqueness_of :manufacturer_product_code, :allow_nil => true, :allow_blank => true
  validates_presence_of :name, :description, :weight, :tax_class, :supplier
  validates_numericality_of :purchase_price, :weight

  # Something's not right here when creating independent products
  #validates_uniqueness_of :supply_item_id

  # Self-referential association to build products out of
  # other products (e.g. a PC out of components)
  #
  # Calculate prices inside e.g.
  # product.product_sets.first.price.rounded
  has_many :components, :through => :product_sets
  has_many :product_sets, :foreign_key => 'product_id', :class_name => 'ProductSet'

  has_many :product_pictures
  has_many :attachments

  belongs_to :tax_class
  belongs_to :supply_item
  has_many :document_lines
  has_many :static_document_lines
  has_and_belongs_to_many :categories

  belongs_to :supplier

  has_many :margin_ranges

  has_many :notifications
  has_many :users, :through => :notifications
  has_many :links

  scope :featured, -> { where(:is_featured => true) }
  scope :available, -> { where(:is_available => true) }
  scope :visible, -> { where(:is_visible => true) }
  scope :supplied, -> { where("supply_item_id IS NOT NULL") }
  scope :loss_leaders, -> { where(:is_loss_leader => true) }
  scope :on_sale, -> { where(:sale_state => true) }
  scope :having_unavailable_supply_item, -> { joins(:supply_item).where("supply_items.status_constant != #{SupplyItem::AVAILABLE}") }


  # === AR callbacks
  before_save :calculate_rounding_component, :set_explicit_sale_state, :cache_calculations
  before_save :update_notifications, :sync_supply_item_information
  before_create :try_to_get_product_description
  after_create :try_to_get_product_files  
  after_save :extract_urls_from_description
  after_save ThinkingSphinx::RealTime.callback_for(:product)

  def update_notifications
    price_relevant_fields = ["purchase_price", "sales_price"]
    relevant_changes = self.changes.keys & price_relevant_fields

    if relevant_changes.size > 0
      Notification.where(:product == self).each do |notification|
        notification.set_active
      end
    end
  end

  sphinx_scope(:sphinx_available) {
    {
    :with => { :is_available => 1}
    }
  }

  sphinx_scope(:sphinx_visible) {
    {
    :with => { :is_visible => 1}
    }
  }

  sphinx_scope(:sphinx_featured) {
    {
    :with => { :is_featured => 1}
    }
  }


  # Pagination with will_paginate
  def self.per_page
    return 30
  end

  def cache_calculations
    self.cached_price = gross_price - calculate_rebate(gross_price)
    self.cached_taxed_price = cached_price + taxes
  end

  def price
    cached_price || gross_price - calculate_rebate(gross_price)
  end

  def taxed_price
    cached_taxed_price || price + taxes
  end

  # The gross price is the price + margin (or sales price, in case of absolutely
  # priced goods). Taxes and rebate are not yet processed here.
  def gross_price
    if componentized?
      gross_price = component_gross_price
    else
      absolutely_priced? ? gross_price = sales_price : gross_price = calculated_gross_price
    end

    return gross_price
  end

  def calculate_rebate(full_price)
    rebate = BigDecimal.new("0")
    end_date = rebate_until || DateTime.new(1940,01,01) 

    if DateTime.now < end_date
      if absolute_rebate?
        rebate = absolute_rebate
      elsif percentage_rebate?
        rebate = (full_price / BigDecimal.new("100.0")) * percentage_rebate
      end
    end
    # This check makes sure only loss-leader products can go below their purchase
    # price through a rebate.
    if (full_price - rebate) < purchase_price
      unless is_loss_leader?
        rebate = 0
      end
    end 
    return rebate
  end

  def rebate
    calculate_rebate(gross_price)
  end

  def absolute_rebate?
    !absolute_rebate.blank? and absolute_rebate > 0
  end

  def percentage_rebate?
    !percentage_rebate.blank? and percentage_rebate > 0
  end


  # Returns the taxes owed on the sales price of a product. 
  def taxes
    calculation = BigDecimal.new("0")
    absolutely_priced? ? base_price = sales_price : base_price = gross_price
    calculation = ( (base_price - rebate) / BigDecimal.new("100.0")) * tax_class.percentage
  end

  def margin
    if componentized?
      component_margin
    else
      if absolutely_priced?
        sales_price - purchase_price
      else
        calculated_margin
      end
    end
  end

  # Calculates all three pricing items (gross price, margin and compound purchase price) for products
  # that consist of multiple products. This assigns all three results in one go so that
  # a lot less calculation is necessary.
  def calculate_component_pricing
    purchase_price = BigDecimal.new("0")
    price = BigDecimal.new("0")
    margin = BigDecimal.new("0")
    # Safeguard to prevent calculation on straightforward simple products
    if componentized?  
      self.product_sets.each do |ps|
        # Components can disappear if their supply items disappear.
        # This is handled more elegantly by disabling these components from outside
        # when this occurs, but let's check for this here just to be safe.
        unless ps.component.nil?
          purchase_price += ps.purchase_price # Convenience method that does ps.quantity * ps.component.purchase_price
        end
      end

      margin = (purchase_price / BigDecimal.new("100.0")) * self.applicable_margin_percentage_for_price(purchase_price) # Must not call through self.margin_percentage, because otherwise an infinite loop occurs
      gross_price = purchase_price + margin
      margin = BigDecimal.new(margin.to_s)
      gross_price = BigDecimal.new(gross_price.to_s)
    end
    @component_pricing ||= [gross_price, margin, purchase_price]
    return @component_pricing
  end

  def component_gross_price
    calculate_component_pricing
    return @component_pricing[0] + rounding_component
  end

  def component_margin    
    calculate_component_pricing
    return @component_pricing[1]
  end
  
  def component_purchase_price
    calculate_component_pricing
    return @component_pricing[2]
  end
  

  
  def add_component(product, quantity = 1)
    unless product.class.name == "SupplyItem"
      raise ArgumentError, "Only supply items can be added as components to other products."
    end

    incremented = false
    saved = false
    
    self.product_sets.each do |ps|
      # Found an existing product set with the same component/product
      # pair, thus we just augment
      if ps.component == product
        ps.quantity += quantity
        if ps.save
          incremented = true
          saved = true
        end
      end
    end
    
    # No existing pair was found, we need to create a new one
    if incremented == false
      ps = ProductSet.new
      ps.quantity = quantity
      ps.component = product
      ps.product = self
      if ps.save
        saved = true
        self.reload
      end
    end
    return saved
  end
  
  
  def remove_component(component, quantity)
    result = false
    quantity = quantity.to_i
    
    self.product_sets.each do |ps|
      if ps.component == component
        if (ps.quantity - quantity) <= 0
          result = true if ps.destroy
        else
          ps.quantity = ps.quantity - quantity
          result = true if ps.save
        end
        self.reload
      end
    end
    return result
  end
  
  # Returns how many of these products we could build based on the stock levels of
  # its components at our suppliers.  
  def component_stock
    stock_levels = []
    product_sets.each do |ps|
      # If any component's stock is below the required quantity, we can impossibly
      # put together this product, so stock becomes immediately 0 as soon as we
      # hit one of these combinations.
      if ps.quantity > ps.component.stock
        stock_levels = [0]
        break        
      else
        # Since we are computing stock from integers, we will always receive the maximum
        # number of constructable products per component from the division.
        # Just as if we had used this more explicit calcluation:
        # (ps.component.stock.to_f / ps.quantity.to_f).floor
        stock_levels << (ps.component.stock.to_i / ps.quantity.to_i)
      end
    end
    return stock_levels.min
  end
  
  
  def self.new_from_supply_item(si)
    p = self.new
    p.name = si.name
    p.manufacturer = si.manufacturer
    p.product_link = si.product_link
    p.description = si.description
    p.purchase_price = si.purchase_price
    # Can be improved by flexibly reading the tax percentage from the CSV file in a first
    # step and then assigning it to a supply item, and THEN reading a proper TaxClass object from there
    if DateTime.new(2018, 01, 01) > DateTime.now
      p.tax_class = TaxClass.find_or_create_by(:percentage => "7.7", :name => "Auto-created 7.7")
    else
      p.tax_class = TaxClass.find_or_create_by(:percentage => "8.0", :name => "Auto-created default")
    end
    p.supplier_id = si.supplier_id
    p.supply_item_id = si.id
    p.weight = si.weight
    p.supplier_product_code = si.supplier_product_code
    p.manufacturer_product_code = si.manufacturer_product_code
    p.ean_code = si.ean_code
    p.stock = si.stock
    return p
  end

  def to_s
    return "#{id} #{name}"
  end  
  
  # CSV export functions.
  
  # Generate a header matching the kind of columns that are actually available for
  # our Product objects.
  def self.csv_header
    ["id","manufacturer","manufacturer_product_code","name","description",\
     "price_excluding_vat", "price_including_vat", "price_including_shipping",\
     "vat", "shipping_cost_excluding_vat", "stock", "availability", "weight_in_kg", "link",\
     "image_link","factsheet_link","ean_code","categories", "shipping_cost_including_vat"]
  end
  
  # Convert this particular product instance into a CSV-compatible representation
  # that matches the header columns as given by Product.csv_header
  def to_csv_array
    base_url = "http://www.lincomp.ch"
    c = Cart.new
    c.add_product(self)
    shipped_price = (taxed_price.rounded + c.shipping_cost.rounded)
    availability = "48h"
    if stock < 1
      availability = "ask"
    end
    unless product_pictures.main.empty?
      image_link = base_url + product_pictures.main.first.file.url unless product_pictures.main.first.file.blank?
    end
    unless attachments.empty?
      factsheet_link = base_url + attachments.first.file.url unless attachments.first.file.blank?
    end
    unless categories.empty?
      categories_arr = [] 
      categories.each do |c|
        categories_arr << c.fully_qualified_name
      end
      categories_string = categories_arr.join("|")
    end

    # We use string interpolation notation (#{foo}) so that nil errors are already
    # handled gracefully without any extra work.
    ["#{id}", "#{manufacturer}" ,"#{manufacturer_product_code}", "#{name}",\
     "#{description}", "#{price.rounded}", "#{taxed_price.rounded}", "#{shipped_price}",\
     "#{taxes}", "#{c.shipping_cost.rounded}", "#{stock}", "#{availability}", "#{weight}",\
     "#{base_url}/products/#{self.id}","#{image_link}","#{factsheet_link}","#{ean_code}",\
     "#{categories_string}","#{c.total_taxed_shipping_price.rounded}"]
  end
  
  def calculated_margin_percentage
    percentage = (BigDecimal.new("100.0") / gross_price) * margin
    BigDecimal.new(percentage.to_s)
  end

  def applicable_margin_percentage_for_price(price)
    if !self.margin_ranges.empty?
      MarginRange.percentage_for_price(price, self.margin_ranges)
    elsif (!self.supplier.nil? and !self.supplier.margin_ranges.empty?)
      MarginRange.percentage_for_price(price, supplier.margin_ranges)
    else
      MarginRange.percentage_for_price(price, MarginRange.where(:supplier_id => nil, :product_id => nil))
    end
  end

  def margin_percentage
    #MarginRange.percentage_for_price(self.purchase_price)
    self.applicable_margin_percentage_for_price(self.purchase_price)
    

  end
    
  # Boolean statuses that need processing (non-trivial booleans that can't be handled by ActiveRecord itself)
  
  def in_a_document?
    state = false
    state = true if document_lines.count > 0
    return state
  end
  
  def componentized?    
    !self.components.empty?
  end
  
  def on_sale?
    rebate > 0
  end

  
    # Is this product priced via an absolutely defined sales price?
  def absolutely_priced?
    if sales_price.nil? or sales_price.blank? or sales_price == BigDecimal.new("0.0")
      return false
    else
      return true
    end
  end
  
  def profitable?
    price > purchase_price
  end
 
  def available?
    is_available == true
  end
  
  def thumbnail_picture
    pic = product_pictures.main.first
    if pic.nil?
      pic = product_pictures.first
    end
    return pic
  end
  
  def set_explicit_sale_state
    self.sale_state = false
    self.sale_state = true if on_sale?
  end
  
  # Attribute overrides
  
  def weight
    weight = 0
    if self.componentized?
      self.product_sets.each do |ps|
        weight += ps.weight
      end
    else
      weight = read_attribute :weight
    end
    
    return weight
  end
  
  def purchase_price
    if self.componentized?
      return self.component_purchase_price
    else
      return read_attribute :purchase_price
    end
  end

  def stock
    if self.componentized?
      return self.component_stock
    else
      return read_attribute :stock
    end    
  end
  
  
  def disable_product
    self.is_available = false
    self.is_visible = false
    if self.save
      History.add("Disabled product #{self.to_s}.", History::PRODUCT_CHANGE, self)
      History.add("Made product invisible #{self.to_s}.", History::PRODUCT_CHANGE, self)
    else
      History.add("Could not disable product #{self.to_s}.", History::PRODUCT_CHANGE, self)
    end
  end

  def enable_product
    self.is_available = true
    if self.save
      History.add("Enabled product #{self.to_s}.", History::PRODUCT_CHANGE, self)
    else
      History.add("Could not enable product #{self.to_s}.", History::PRODUCT_CHANGE, self)
    end
  end

  def has_unavailable_supply_item?
    unless self.supply_item.blank?
      Product.having_unavailable_supply_item.where(:id => self.id).count == 1
    end
  end
  
  def has_unavailable_components?
      self.components.unavailable.count > 0
  end
  
  def unavailable_components
    if self.componentized?
      self.components.unavailable
    end
  end

  # Returns a URL pointing to that particular product on the supplier's web page
  def supplier_detail_link
    if supplier.product_base_url.blank? or self.supplier_product_code.blank?
      return nil
    else
      return "#{supplier.product_base_url}#{self.supplier_product_code}"
    end
  end
  
  # Compare all products that are related to a supply item with
  # the supply item's current stock level and price. Make adjustments
  # as necessary.
  def self.update_price_and_stock
    price_update_logger ||= Logger.new("#{Rails.root}/log/price_and_stock_update_#{DateTime.now.to_s.gsub(":","-")}.log")
    
    ThinkingSphinx::Deltas.suspend :product do
      Product.supplied.find_each do |p|
        # The supply item is no longer available, thus we need to
        # make our own copy of it unavailable as well

        # The product has a supplier, but its supply item is gone
        if p.supply_item.nil? and !p.supplier_id.blank?
          p.disable_product
          price_update_logger.info("[#{DateTime.now.to_s}] Disabled product #{p.to_s} because its supply item is gone.")
        else
          # Disabling product because we would be incurring a loss otherwise
          if (p.absolutely_priced? and p.supply_item.purchase_price > p.sales_price)
            p.is_available = false
            p.save
            price_update_logger.info("[#{DateTime.now.to_s}] Disabled product #{p.to_s} because purchase price is higher than absolute sales price.")

          else

            # Find out if there is a cheaper supply item to switch to
            if p.cheaper_supply_item_available?
              supply_item = p.assign_cheapest_supply_item
              price_update_logger.info("[#{DateTime.now.to_s}] Switched product #{p.to_s} to cheaper supply item #{supply_item.to_s}")
            elsif (p.supply_item.stock <= 0 or p.supply_item.status_constant == SupplyItem::DELETED) and p.alternative_available_supply_items.count > 0
              p.supply_item = p.alternative_available_supply_items.first
              supply_item = p.supply_item 
              p.is_available = true
              price_update_logger.info("[#{DateTime.now.to_s}] Switched product #{p.to_s} to alternative supply item #{supply_item.to_s}")
            else
              supply_item = p.supply_item
            end

            changes = p.sync_from_supply_item(supply_item)
            unless changes.empty?
              if p.save
                price_update_logger.info("[#{DateTime.now.to_s}] Product update: #{p.to_s}. Changes: #{changes.inspect}")
              else
                price_update_logger.error("[#{DateTime.now.to_s}] Product update failed: #{p.to_s}. Changes: #{changes.inspect}. Errors: #{p.errors.full_messages}")
              end
            end
          end
        end
      end
    end
  end
  
  def sync_from_supply_item(supply_item = self.supply_item)
    self.name = supply_item.name
    unless self.is_description_protected?
      self.description = supply_item.description unless (supply_item.description.blank? or !supply_item.description_url.blank?)
    end
    self.stock = supply_item.stock
    self.purchase_price = supply_item.purchase_price
    self.manufacturer = supply_item.manufacturer
    self.manufacturer_product_code = supply_item.manufacturer_product_code
    self.ean_code = supply_item.ean_code
    self.supplier_product_code = supply_item.supplier_product_code
    self.supplier = supply_item.supplier
    changes = self.changes
    return changes
  end

  def try_to_get_product_files
    unless self.supply_item.nil?
      if self.supply_item.reload.retrieve_product_picture
        if self.product_pictures.count == 1
          self.product_pictures.first.set_main_picture
        end
      end
      self.supply_item.retrieve_pdf
    end
  end


  # If an URL to retrieve a product description from is set on this product's supply item,
  # try to retrieve its product description from there and overwrite our own.
  def try_to_get_product_description
    unless self.supply_item.nil?
      gotten_description = self.supply_item.get_description
      self.description = gotten_description unless (gotten_description == false or gotten_description.blank? or gotten_description.nil?)
    end
  end
  
  def alternative_supply_items?
    alternative_supply_items.count > 0
  end
  
  def alternative_supply_items
    candidates = SupplyItem.where("manufacturer_product_code != ''")\
                           .where(:manufacturer_product_code => supply_item.manufacturer_product_code)\
                           .where("id <> #{supply_item.id}")\
                           .order("purchase_price ASC")

    unless self.manufacturer.blank?
      candidates = candidates.where("((manufacturer IS NULL) or (manufacturer = '') or  (manufacturer LIKE '#{self.manufacturer[0]}%'))")
    end

    # If there is an EAN in addition to the manufacturer product code, compare those as well and
    # discard things that don't match
    if self.ean_code
      candidates = candidates.where(:ean_code => self.ean_code)
    end
    return candidates
  end

  def sync_supply_item_information
    if supply_item_id_changed?
      self.sync_from_supply_item
    end
  end

  def self.export_available_to_csv(filename)
    require 'csv'
    CSV.open("#{filename}.tmp", "w", :col_sep => ",", :quote_char => '"') do |csv|
      csv << Product.csv_header
      Product.available.find_each do |p|
        csv << p.to_csv_array
      end
    end
    if FileUtils.mv("#{filename}.tmp", filename) == 0
      result = `zip -rj "#{File.dirname(filename)}/#{File.basename(filename, '.*')}.zip" "#{filename}"`
      result_code = $?
      if result_code.exitstatus == 0
        return true 
      else
        return false
      end
    else
      return false
    end
  end

  def calculate_rounding_component
    absolute_rebate_for_rounding = BigDecimal.new("0.0")
    percentage_rebate_for_rounding = BigDecimal.new("0.0")

    end_date = rebate_until || DateTime.new(1940,01,01)
    if DateTime.now < end_date
      absolute_rebate_for_rounding = absolute_rebate
      percentage_rebate_for_rounding = percentage_rebate
    end

    self.rounding_component = ProductRoundingCalculator.calculate_rounding_component(:purchase_price => self.purchase_price, 
                                                                                     :margin_percentage => self.margin_percentage, 
                                                                                     :tax_percentage => self.tax_class.percentage,
                                                                                     :absolute_rebate => absolute_rebate_for_rounding,
                                                                                     :percentage_rebate => percentage_rebate_for_rounding)
  end

  def cheaper_supply_items
    cheaper_supply_items = []
    unless self.supply_item.nil?
      potentially_cheaper_supply_items = SupplyItem.in_stock.available.where("manufacturer_product_code != ''")\
                                                                      .where(:manufacturer_product_code => self.supply_item.manufacturer_product_code)\
                                                                      .order("purchase_price ASC")

      unless self.manufacturer.blank?
        potentially_cheaper_supply_items = potentially_cheaper_supply_items.where("((manufacturer IS NULL) or (manufacturer = '') or  (manufacturer LIKE '#{self.manufacturer[0]}%'))")
      end

      if self.ean_code
        potentially_cheaper_supply_items = potentially_cheaper_supply_items.where(:ean_code => self.ean_code)
      end

      cheaper_supply_items = potentially_cheaper_supply_items.select{|si|
        if si.supplier and !si.supplier.margin_ranges.empty?
          margin_ranges = si.supplier.margin_ranges
        else
          margin_ranges = MarginRange.system_wide_ranges
        end
        price = si.purchase_price
        margin_percentage = MarginRange.percentage_for_price(price, margin_ranges)
        margin = (price / BigDecimal.new("100.0")) * margin_percentage
        si if (price + margin) < self.gross_price
      }
    end
    return cheaper_supply_items
  end

  def assign_cheapest_supply_item
    self.supply_item = self.cheaper_supply_items.first unless self.cheaper_supply_items.empty? # Since it's ordered by purchase price, picking the first is safe
    return self.supply_item
  end

  def switch_to_cheapest_supply_item
    self.assign_cheapest_supply_item
    return self.save
  end

  def cheaper_supply_item_available?
    self.cheaper_supply_items.count >= 1
  end

  def alternative_available_supply_items
    self.alternative_supply_items.in_stock.available
  end
  
  def extract_urls_from_description
    found_links = URI.extract(self.description, "http")
    found_links.each do |fl|
      fl.gsub!(/[\.|,]+$/, "") # Strip . and , from the end, as they might be sentence punctuation from the description
      self.links.create(:url => fl) unless self.links.exists?(:url => fl)
    end
  end

  private

  def calculated_gross_price
    #calculated_gross_price = (purchase_price + calculated_margin + calculate_swiss_rounding_component(purchase_price, self.margin_percentage))
    #calculated_gross_price = (purchase_price + calculated_margin + rounding_component)
    calculated_gross_price = (purchase_price + calculated_margin)
    #
    calculated_gross_price
  end
  
  def calculated_margin
    margin = (purchase_price / BigDecimal.new("100.0")) * BigDecimal.new(self.margin_percentage.to_s)
    margin
  end

  
end
