class StoreActions < ActiveRecord::Migration[5.0]
  def change
  	create_table :customer_actions do |t|
      t.datetime :created
      t.string :shopify_id
      t.string :email
      t.string :recharge_subscription_id
      t.string :action
      t.string :cancellation_reason
      t.boolean :shopify_updated
      t.boolean :klaviyo_updated
    end
  end
end
