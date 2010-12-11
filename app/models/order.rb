class Order < Document

  # === Associations
  belongs_to :user
  has_many :order_lines
  has_one :invoice 
  
  belongs_to :shipping_address, :polymorphic => true
  belongs_to :billing_address, :polymorphic => true
  belongs_to :payment_method
  
  # === Validations
  
  validates_presence_of :billing_address
  
  validates_associated :billing_address, :message => 'is incomplete'
  validates_associated :shipping_address, :unless => :addressing_ok?, :message => 'is incomplete'
  
  validate :must_be_authorized_for_payment_method
  
  after_initialize :assign_payment_method
  before_create :assign_document_number
  
  
  # This doesn't seem to work at all, or at least not as advertised
  # Might be fixed in Rails 3.0 (polymorphic association + nested forms)
  #accepts_nested_attributes_for :shipping_address
  #accepts_nested_attributes_for :billing_address

  
  # === Constants and associated methods

  # Rails 3.0 will have ActiveRecord.state_machine that will
  # take care of this better (with transitions), but we 
  # cannot use that in 2.3. We might want to look into has_states
  # at some point: http://github.com/sbfaulkner/has_states
  UNPROCESSED = 1
  PROCESSING = 2
  AWAITING_PAYMENT = 3
  SHIPPED = 4
  TO_SHIP = 5
  
  STATUS_HASH = { UNPROCESSED      => I18n.t('stizun.constants.unprocessed'),
                  PROCESSING       => I18n.t('stizun.constants.processing'),
                  AWAITING_PAYMENT => I18n.t('stizun.constants.awaiting_payment'),
                  TO_SHIP          => I18n.t('stizun.constants.to_ship'),
                  SHIPPED          => I18n.t('stizun.constants.shipped')}

  def self.status_to_human(status)
    return STATUS_HASH[status]
  end
  
  def self.status_hash_for_select
    array = []
    STATUS_HASH.each do |key,value|
      array << [value, key]
    end 
    # Sort by value of the constant integer, so the sequence of
    # statuses is more or less the same as it appears in the
    # workflow.
    return array.sort {|a, b| a[1] <=> b[1]}
  end
  
  def status_human
    return Order::status_to_human(status_constant)
  end  
  
  # === Named scopes
  
  scope :unprocessed, :conditions => { :status_constant => Order::UNPROCESSED }
  scope :processing, :conditions => { :status_constant => Order::PROCESSING }
  scope :awaiting_payment, :conditions => { :status_constant => Order::AWAITING_PAYMENT }
  scope :shipped, :conditions => { :status_constant => Order::SHIPPED }
  scope :to_ship, :conditions => { :status_constant => Order::TO_SHIP }
  
  scope :pending_from_user_perspective, :conditions => "status_constant == ?" # TODO: is this working yet?
  
  # TODO: Verify if this is working
  before_save { |record|
    if record.shipping_address.blank?
      record.shipping_address = record.billing_address
    end
  }
  
  
  # === Methods
  
  def invoiced?
    return !invoice.blank?
  end

  def document_id
    return "O-#{document_number}"
  end
  
  # Static method, should be used whenever creating an order
  # based on a pre-existing cart, e.g. during checkout
  def self.create_from_cart(cart)
    order = self.new
    order.order_lines_from_cart(cart)
    return order
  end
  
  # The same, but works with an existing Order object
  def order_lines_from_cart(cart)
    order = self
    cart.cart_lines.each do |cl|
      ol = OrderLine.create(cl.attributes)
      ol.cart_id = nil
      order.order_lines << ol
    end
    return order
  end
    
  
  # This is used in validation.
  # If neither address is filled in, validate both.
  # If only the billing address is filled in, validate just that
  def addressing_ok?
    if billing_address.nil?
      return false
    elsif billing_address.filled_in? and (shipping_address.nil? or !shipping_address.filled_in?)
      return true
    elsif billing_address.filled_in? and shipping_address.filled_in?
      return false
    else
      return false
    end
  end
  
  # Alias for order_lines so that generic order|invoice.lines works
  def lines
    order_lines
  end

  
  # A locked order's order_lines may not be changed anymore.
  # This is to prevent invoiced orders from being changed, otherwise
  # the invoice would no longer be correct.
  # TODO: This is probably no longer necessary now that we save invoices
  # as lists of independent text strings instead of using product
  # references.
  def locked?
    locked = false
    status_constant == Order::UNPROCESSED ? locked = false : locked = true
    locked = true unless invoice.blank?
    return locked
  end
  
  
  # Orders may only allow direct shipping if all of the products they
  # contain can be shipped directly from supplier warehouses to the customer.
  def direct_shipping?
    direct = true
    direct = false if lines.collect(&:product).collect(&:direct_shipping).include?(false)
    direct = false if payment_method.allows_direct_shipping? == false
    return direct
  end
  
  
  # If the user doesn't actually have authorization for this payment method, e.g. a user
  # who must pre-pay tries to order something on credit, the order can't be saved.
  # It should actually never be possible for a user to pass an unauthorized payment type,
  # but this check prevents errors e.g. from admins manipulating orders on the console.
  def must_be_authorized_for_payment_method
 
    unless payment_method == PaymentMethod.get_default or user.payment_methods.include?(payment_method) or  
      errors.add_to_base("User is not authorized for the chosen payment method.")
    end
    
  end
  
  def send_order_confirmation(user)
    # Is this require really required? Just to have some errors
    # that we can rescue?
    require 'net/smtp'
    begin
      StoreMailer.deliver_order_confirmation(user, self)
    rescue Net::SMTPAuthenticationError, Net::SMTPServerBusy, Net::SMTPSyntaxError, Net::SMTPFatalError, Net::SMTPUnknownError => e
      History.add("Could not send order confirmation for order  #{self.document_id} during checkout: #{e.to_s}", History::GENERAL, self)
    end
  end
  
  
  # === ActiveRecord callbacks
  
  def assign_document_number
    self.document_number ||= Numerator.get_number
  end
    
  def assign_payment_method
    self.payment_method ||= PaymentMethod.get_default
  end
  
end
