require 'spec_helper'

describe Document do
  
  before(:all) do
    mr0 = FactoryGirl.build(:margin_range)
    mr0.start_price = nil
    mr0.end_price = nil
    mr0.margin_percentage = 5.0
    mr0.save
  
    @tax_class = FactoryGirl.create(:tax_class, {:percentage => 50.0})
    
    @sc = ShippingCalculatorBasedOnWeight.create(:name => 'For Testing')
    @sc.configuration.shipping_costs = []
    @sc.configuration.shipping_costs << {:weight_min => 0, :weight_max => 10000, :price => 10.0}
    @sc.tax_class = @tax_class
    @sc.save
    ConfigurationItem.create(:key => 'default_shipping_calculator_id', :value => @sc.id)

    @supplier = FactoryGirl.create(:supplier)
    
    Country.create(:name => "Somewhereland")
    @address = Address.new(:street => 'Foo',
                  :firstname => 'Foo',
                  :lastname => 'Bar',
                  :postalcode => '1234',
                  :city => 'Somewhere',
                  :email => 'lala@lala.com',
                  :country => Country.first)    
    @address.save.should == true
    
    
    p = Product.new(:name => "foo", :description => "bar", :weight => 5.5, :supplier => @supplier, :tax_class => @tax_class, :purchase_price => 100.0, :direct_shipping => true, :is_available => true)
    p.save.should == true
    
  end
  
  context "when deciding about free shipping" do
    it "should consider only after-tax prices" do
      ConfigurationItem.create(:key => "free_shipping_minimum_amount", :value => 120)
      c = Cart.new
      c.add_product(Product.first)
      c.save
      c.products_taxed_price.should >= 120
      # Before tax, this product would cost 100.00. After tax, 150.00. The minimum amount
      # for free shipping is 120.00, so we should offer free shipping now.
      c.shipping_cost.should == BigDecimal.new("0.0")
      c.shipping_taxes.should == BigDecimal.new("0.0")
    end
    
    it "should report the correct total including taxes and shipping" do
      ConfigurationItem.create(:key => "free_shipping_minimum_amount", :value => 120)
      c = Cart.new
      c.add_product(Product.first)
      c.save
      
      c.shipping_cost.should == BigDecimal.new("0.0")
      c.shipping_taxes.should == BigDecimal.new("0.0")
      c.taxed_price.should == c.products_taxed_price # No added shipping!
    end
  end
  
end
