class RelateProductsToSupplyItems < ActiveRecord::Migration
  def self.up
    add_column :products, :supply_item_id, :integer
  end

  def self.down
    remove_column :products, :supply_item_id
  end
end
