Feature: Browse products

  So that a customer can buy something
  They need to be able to browse our products

    Background: Set up some necessary things
      Given a category named "Notebooks" exists
      And there is a configuration item named "currency" with value "CHF"
      And there is a user with e-mail address "admin@something.com" and password "foobar"
      And a tax class named "MwSt 8.0%" with the percentage 8.0%
      And the user group "Admins" exists
      And the user group "Admins" has admin permissions
      And the user is member of the group "Admins"
      And I log in with e-mail address "admin@something.com" and password "foobar"
      And there is a default shipping calculator of type ShippingCalculatorBasedOnWeight called "Alltron AG" with the following costs:
      |weight_min|weight_max|price|
      |         0|      1000|   10|
      |      1001|      2000|   20|
      |      2001|      3000|   30|
      |      3001|      4000|   40|
      |      4001|      5000|   50|
      And there are the following suppliers:
      |name|
      |Alltron AG|
      And there are the following margin ranges:
      |start_price|end_price|margin_percentage|
      |nil        |nil      |0.0              |
      And there is a payment method called "Prepay" which is the default

    Scenario: Browse all products
      Given the following products exist(table):
      |name        |category               |supplier  |purchase_price|manufacturer_product_code|
      |Foobar 2000 |Metasyntactic Variables|Alltron AG|100.0         |foo1                     |
      |Fish        |Animals                |Alltron AG|100.0         |foo2                     |
      |Defender    |Arcade games           |Alltron AG|100.0         |foo3                     |
      And the Sphinx indexes are updated
      When I view the product list
      Then I should see a product named "Foobar 2000"
      And I should see a product named "Fish"
      And I should see a product named "Defender"

    Scenario: Browse products in a category
      Given the following products exist(table):
      |name        |category               |supplier  |purchase_price|manufacturer_product_code|
      |Foobar 2000 |Metasyntactic Variables|Alltron AG|100.0         |foo1                     |
      |Fish        |Animals                |Alltron AG|100.0         |foo2                     |
      |Defender    |Arcade games           |Alltron AG|100.0         |foo3                     |
      And the Sphinx indexes are updated
      And I view the category "Animals"
      Then I should see a product named "Fish"
      And I should not see a product named "Defender"


    Scenario: See featured products
      Given the following products exist(table):
      | name     | category | supplier   | purchase_price | manufacturer_product_code | featured |
      | Penguin  | Animals  | Alltron AG |          100.0 | foo1                      | yes      |
      | Fish     | Animals  | Alltron AG |          100.0 | foo2                      | yes      |
      | Duckling | Animals  | Alltron AG |          100.0 | foo3                      | yes      |
      When the Sphinx indexes are updated
      And I go to the home page
      Then I see the following featured products:
      | name     |
      | Penguin  |
      | Fish     |
      | Duckling |

    Scenario: Build-to-order products
      Given the following products exist(table):
      | name        | category | supplier   | purchase_price | manufacturer_product_code | stock | build_to_order |
      | jET Laptop  | Laptops  | Alltron AG |          100.0 | foo1                      | 0     | yes      |
      | Dell Laptop | Laptops  | Alltron AG |          100.0 | foo2                      | 10    | no      |
      When the Sphinx indexes are updated
      And I view the category "Laptops"
      And I view the product "jET Laptop"
      Then I should be informed that this laptop is build-to-order 
      And I view the category "Laptops"
      And I view the product "Dell Laptop"
      Then I should see a stock level of 10 
