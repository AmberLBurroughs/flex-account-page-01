require 'business_time'
require 'faraday'
require 'json'
require 'pry'
require 'sinatra'
require 'sinatra/activerecord'
require 'sinatra/base'
require 'sinatra/cross_origin'

require './models/customer_action'

SHOPIFY_API_KEY   = ''
SHOPIFY_PASSWORD  = ''
SHOPIFY_SHOP_NAME = 'the-flex-company'
SHOPIFY_BASE_URL  = "https://#{SHOPIFY_API_KEY}:#{SHOPIFY_PASSWORD}@#{SHOPIFY_SHOP_NAME}.myshopify.com"

RECHARGE_API_KEY  = ''
RECHARGE_BASE_URL = 'https://api.rechargeapps.com'

#STRIPE_PUBLIC     = ''
#Stripe.api_key     = ''

register Sinatra::CrossOrigin

# check for shopify users and update actions
Thread.new do
  while true do
    sleep 30
    sync_shopify_metadata()
  end
end

Thread.new do
  while true do
    sleep 30
    sync_klaviyo_data()
  end
end

get '/' do
  redirect 'https://flexfits.com/'
end

get '/subscription/customer' do
  cross_origin :allow_origin => 'https://flexfits.com'
  content_type :json

  # grab get parameters
  customer_email = request['customer_email']
  customer_id = request['customer_id']

  customer_data = get_shopify_user(customer_id, customer_email)
  if params.length === 0 || !customer_data['match']
    redirect 'https://flexfits.com/'
  end

  # use parameters to query shopify api for customer
  customer = customer_data['customer']

  last_order = last_shopify_order(customer['id'])

  subscription_data = subscriber_details(customer)
  recharge_billing = recharge_billing_address(customer_id)
  recharge_shipping = recharge_shipping_address(subscription_data[:address_id])

  if customer['tags'].include?('Active Subscriber')
    return { subscription: subscription_data, last_order: last_order, billing_address: recharge_billing, shipping_address: recharge_shipping  }.to_json
  elsif customer['tags'].include?('Paused Subscription')
    return { subscription: subscription_data.merge({ inactive_subscription: true, inactive_type: 'paused' }), last_order: last_order, billing_address: recharge_billing, shipping_address: recharge_shipping }.to_json
  elsif customer['tags'].include?('Inactive Subscription')
    return { subscription: subscription_data.merge({ inactive_subscription: true, inactive_type: 'cancelled' }), last_order: last_order, billing_address: recharge_billing, shipping_address: recharge_shipping }.to_json
  elsif customer['tags'] == '' && last_order[:shipped]
    return { subscription: { inactive_subscription: true, inactive_type: 'nonsubscriber', active_subscriptions: [] }, last_order: last_order, billing_address: recharge_billing, shipping_address: recharge_shipping }.to_json
  end

  # tell shopify calendar modal to not show anything
  return { subscription: { inactive_subscription: true, inactive_type: 'nonsubscriber', active_subscriptions: [] }, last_order: {}, billing_address: {}, shipping_address: {} }.to_json
  # return customer tags, last order from shopify, order tags, next charge date for most current order from recharge, subscription type
end

get '/subscription/id' do
  cross_origin :allow_origin => 'https://flexfits.com'
  content_type :json

  # grab get parameters
  customer_email = request['customer_email']
  customer_id = request['customer_id']
  subscription_id = request['subscription_id']

  customer_data = get_shopify_user(customer_id, customer_email)
  if params.length === 0 || !customer_data['match']
    redirect 'https://flexfits.com/'
  end

  # use parameters to query shopify api for customer
  customer = customer_data['customer']

  last_order = last_shopify_order(customer['id'])

  subscription_data = subscriber_details(customer)
  if customer['tags'].include?('Active Subscriber')
    return { subscription: subscription_data, last_order: last_order }.to_json
  elsif customer['tags'].include?('Paused Subscription')
    return { subscription: subscription_data.merge({ inactive_subscription: true }), last_order: last_order }.to_json
  end

  # tell shopify calendar modal to not show anything
  return { show_header: false, show_calendar: false}.to_json
  # return customer tags, last order from shopify, order tags, next charge date for most current order from recharge, subscription type
end

post '/subscription/update' do
  cross_origin :allow_origin => 'https://flexfits.com'
  content_type :json

  # grab get parameters
  customer_email = request['customer_email']
  customer_id = request['customer_id']
  next_subscription_time = request['next_subscription_time'].to_i
  subscription_id = request['subscription_id']

  customer_data = get_shopify_user(customer_id, customer_email)
  if params.length === 0 || !customer_data['match']
    redirect 'https://flexfits.com/'
  elsif (next_subscription_time/1000) > (Time.now.to_i + (60 * 60 * 24 * 365))
    # if greater than one year from today, throw an error.
    return { success: false, error_code: 'subscription_time_exceeded'}
  end

  if customer_data['customer']['tags'].include?('Active Subscriber')
    customer_id = customer_data['customer']['id']
    updated_sub = update_recharge_subscription(customer_id, subscription_id, next_subscription_time)
    if updated_sub
      store_customer_action(customer_id, customer_email, subscription_id, 'updated')
      return {success: true}.to_json
    end

    return {success: false, error_code: 'failed_update'}.to_json
  end

  return {success: false}.to_json
end

# endpoint used to PAUSE an active subscription
post '/subscription/pause' do
  cross_origin :allow_origin => 'https://flexfits.com'
  content_type :json

  # grab get parameters
  customer_email = request['customer_email']
  customer_id = request['customer_id']
  subscription_id = request['subscription_id']
  cancellation_reason = request['cancellation_reason']

  customer_data = get_shopify_user(customer_id, customer_email)
  if params.length === 0 || !customer_data['match']
    redirect 'https://flexfits.com/'
  end

  if customer_data['customer']['tags'].include?('Active Subscriber')
    customer_id = customer_data['customer']['id']
    customer_tags = customer_data['customer']['tags']
    paused_sub = pause_recharge_subscription(customer_id, subscription_id, cancellation_reason, customer_tags)
    if paused_sub
      store_customer_action(customer_id, customer_email, subscription_id, 'paused', cancellation_reason=cancellation_reason)
      return {success: true}.to_json
    end

    return {success: false}.to_json
  end

  return {success: false}.to_json
end

# endpoint used to CANCEL an active subscription
post '/subscription/cancel' do
  cross_origin :allow_origin => 'https://flexfits.com'
  content_type :json

  # grab get parameters
  customer_email = request['customer_email']
  customer_id = request['customer_id']
  subscription_id = request['subscription_id']
  cancellation_reason = request['cancellation_reason']

  customer_data = get_shopify_user(customer_id, customer_email)
  if params.length === 0 || !customer_data['match']
    redirect 'https://flexfits.com/'
  end

  if customer_data['customer']['tags'].include?('Active Subscriber')
    customer_id = customer_data['customer']['id']
    customer_tags = customer_data['customer']['tags']
    paused_sub = pause_recharge_subscription(customer_id, subscription_id, cancellation_reason, customer_tags)
    if paused_sub
      store_customer_action(customer_id, customer_email, subscription_id, 'cancelled', cancellation_reason=cancellation_reason)
      return {success: true}.to_json
    end

    return {success: false}.to_json
  end

  return {success: false}.to_json
end

post '/subscription/skip_interval' do
  cross_origin :allow_origin => 'https://flexfits.com'
  content_type :json

  # grab get parameters
  customer_email = request['customer_email']
  customer_id = request['customer_id']
  intervals_skipped = request['intervals_skipped'].to_i
  subscription_id = request['subscription_id']

  customer_data = get_shopify_user(customer_id, customer_email)
  if params.length === 0 || !customer_data['match']
    redirect 'https://flexfits.com/'
  elsif intervals_skipped > 3 # only allow up skipping up to three intervals.
    return { success: false, error_code: 'intervals_exceeded' }.to_json
  end

  subscription_data = get_recharge_subscription(customer_id, subscription_id)
  updated_sub = skip_recharge_intervals(subscription_data, intervals_skipped)
  if updated_sub
    store_customer_action(customer_id, customer_email, subscription_id, 'skipped')
    return {success: true}.to_json
  end

  return {success: false}.to_json
end

# endpoint used to REACTIVATE a paused subscription
post '/subscription/reactivate' do
  cross_origin :allow_origin => 'https://flexfits.com'
  content_type :json

  # grab get parameters
  customer_email = request['customer_email']
  customer_id = request['customer_id']
  subscription_id = request['subscription_id']
  next_subscription_time = request['next_subscription_time'].to_i

  customer_data = get_shopify_user(customer_id, customer_email)
  if params.length === 0 || !customer_data['match']
    redirect 'https://flexfits.com/'
  end

  if customer_data['customer']['tags'].include?('Paused Subscription')
    customer_id = customer_data['customer']['id']
    customer_tags = customer_data['customer']['tags']
    reactivated_sub = reactivate_recharge_subscription(customer_id, subscription_id, next_subscription_time, customer_tags)
    if reactivated_sub
      store_customer_action(customer_id, customer_email, subscription_id, 'reactivated')
      return {success: true}.to_json
    end

    return {success: false, error_code: 'active_subscriber'}.to_json
  end

  return {success: false}.to_json
end

# can update billing address, shipping address, credit card
post '/customer/address' do
  cross_origin :allow_origin => 'https://flexfits.com'
  content_type :json

  customer_email = request['customer_email']
  customer_id = request['customer_id']
  # customer_billing and customer_shipping are hashes.
  customer_billing = request['customer_billing']
  customer_shipping = request['customer_shipping']

  recharge_customers = get_recharge_customer(customer_id)

  if recharge_customers.length == 1
    recharge_customer = recharge_customers[0]
    updated_customer = update_recharge_customer(recharge_customer['id'], customer_billing, customer_shipping)
    return {success: true}.to_json if updated_customer
  end

  return {success: false}.to_json
end

def store_customer_action(customer_id, customer_email, subscription_id, action_taken, cancellation_reason=nil)
  ca = CustomerAction.new
  ca.created = DateTime.now
  ca.shopify_id = customer_id
  ca.email = customer_email
  ca.recharge_subscription_id = subscription_id
  ca.action = action_taken
  ca.cancellation_reason = cancellation_reason
  ca.shopify_updated = true
  ca.klaviyo_updated = true

  if action_taken != 'updated'
    ca.shopify_updated = false
    ca.klaviyo_updated = false
  end

  ca.save!
end

def last_shopify_order(customer_id)
  conn = shopify_connection()
  shopify_response = conn.get do |req|
    req.url "/admin/customers/#{customer_id}/orders.json"
    req.body = { limit: 10, status: 'any', financial_status: 'any', fulfillment_status: 'any' }
  end

  all_orders = JSON.parse(shopify_response.body)
  active_orders = all_orders['orders'].select{ |ord| ord['status'] != 'cancelled' }
  if active_orders.length > 0
    tracking_url = active_orders[0]['fulfillment_status'] == 'fulfilled' ? active_orders[0]['fulfillments'][0]['tracking_url'] : nil
    delivery_date = calculate_delivery(active_orders[0])
    return { shipped: true, estimated_delivery: delivery_date, tracking_url: tracking_url  }
  else
    return { shipped: false}
  end
end

# create new faraday connection
def shopify_connection
  Faraday.new(url: SHOPIFY_BASE_URL, ssl: { verify: false }) do |faraday|
    faraday.request  :url_encoded             # form-encode POST params
    faraday.adapter  Faraday.default_adapter  # make requests with Net::https
  end
end

def recharge_connection
  Faraday.new(url: RECHARGE_BASE_URL, ssl: { verify: false }) do |faraday|
    faraday.request  :url_encoded             # form-encode POST params
    faraday.adapter  Faraday.default_adapter  # make requests with Net::https
  end
end

# On page load, show this information.
def subscriber_details(customer, subscription_id=nil)
  last_sub_order = last_shopify_subscription(customer)
  return { inactive_subscription: true } if last_sub_order.nil?

  is_first_sub = last_sub_order['tags'].include?('Subscription First Order')

  order_titles = last_sub_order['line_items'].map{ |li| li['title']}
  is_8pack = order_titles.any? { |ot| ot.include?('8 Pack')}

  # query recharge api for next charge date
  recharge_data = get_recharge_data(customer['id'])

  if subscription_id == nil
    desired_subscription = recharge_data[0]
  else
    desired_subscription = recharge_data.select{ |sub| sub['id'] == subscription_id }[0]
  end

  frequency = "#{desired_subscription['order_interval_frequency']} #{desired_subscription['order_interval_unit']}s"
  subscription_id = desired_subscription['id']
  active_subscriptions = recharge_data.map { |rd| rd['id'] }

  if desired_subscription['status'] == 'ACTIVE'
    next_scheduled_date = Date.strptime(desired_subscription['next_charge_scheduled_at'])
    skipped_interval_dates = potential_skip_intervals(desired_subscription)
    calendar_date = 5.business_days.after(next_scheduled_date).to_time.to_i * 1000
  else
    calendar_date = nil
    skipped_interval_dates = nil
  end

  return { subscription_id: subscription_id, address_id: desired_subscription['address_id'],  frequency: frequency, skipped_interval_dates: skipped_interval_dates, calendar_date: calendar_date, subscription_type: desired_subscription['product_title'], inactive_subscription: false, active_subscriptions: active_subscriptions }
end

def potential_skip_intervals(subscription_data)
  interval_1 = skip_delivery_until(subscription_data, 1).to_time.to_i * 1000
  interval_2 = skip_delivery_until(subscription_data, 2).to_time.to_i * 1000
  interval_3 = skip_delivery_until(subscription_data, 3).to_time.to_i * 1000
  return [interval_1, interval_2, interval_3]
end

# hacky security goes here: for a given customer ID
# and user email, check that the email is actually associated
# with this customer ID.
# (only the user should know this!)
def get_shopify_user(customer_id, email)
  conn = shopify_connection()

  response = conn.get do |req|
    req.url "/admin/customers/#{customer_id}.json"
  end
  customer = JSON.parse(response.body)['customer']
  customer_match = customer.nil? ? false : customer['email'] == email
  { 'customer' => customer, 'match' => customer_match }
end

def last_shopify_subscription(customer_json)
  conn = shopify_connection()

  response = conn.get do |req|
    req.url "/admin/orders.json"
    req.params = {'customer_id': customer_json['id'], 'status': 'any'}
  end

  orders_json = JSON.parse(response.body)['orders']
  orders_json.each do |order|
    return order if order['tags'].include?('Subscription') && order['status'] != 'cancelled'
  end

  return nil
end

def get_recharge_data(shopify_customer_id)
  conn = recharge_connection()

  subscription_response = conn.get do |req|
    req.url "/subscriptions"
    req.headers['X-Recharge-Access-Token'] = RECHARGE_API_KEY
    req.params = { 'shopify_customer_id': shopify_customer_id }
  end

  subscriptions = JSON.parse(subscription_response.body)['subscriptions']
end

def recharge_billing_address(shopify_customer_id)
  customers = get_recharge_customer(shopify_customer_id)

  if customers.length == 1
    customer = customers[0]
    return {
      billing_first_name: customer['billing_first_name'],
      billing_last_name: customer['billing_last_name'],
      billing_address1: customer['billing_address1'],
      billing_address2: customer['billing_address2'],
      billing_zip: customer['billing_zip'],
      billing_city: customer['billing_city'],
      billing_province: customer['billing_province'],
      billing_country: customer['billing_country'],
      billing_phone: customer['billing_phone']
    }
  end
end

def recharge_shipping_address(address_id)
  conn = recharge_connection()

  response = conn.get do |req|
    req.url "/addresses/#{address_id}"
    req.headers['X-Recharge-Access-Token'] = RECHARGE_API_KEY
  end

  address = JSON.parse(response.body)['address']
  if address
    return {
      shipping_first_name: address['first_name'],
      shipping_last_name: address['last_name'],
      shipping_address1: address['address1'],
      shipping_address2: address['address2'],
      shipping_zip: address['zip'],
      shipping_city: address['city'],
      shipping_province: address['province'],
      shipping_country: address['country'],
      shipping_phone: address['phone']
    }
  else
    return {}
  end
end

def get_recharge_customer(shopify_customer_id)
  conn = recharge_connection()

  response = conn.get do |req|
    req.url "/customers"
    req.headers['X-Recharge-Access-Token'] = RECHARGE_API_KEY
    req.params = { 'shopify_customer_id': shopify_customer_id }
  end

  customers = JSON.parse(response.body)['customers']
end

def update_recharge_customer(recharge_customer_id, customer_billing, customer_shipping)
  updated_billing = true
  updated_shipping = true

  if !customer_billing.nil? && valid_billing_details(customer_billing)
    updated_billing = change_recharge_billing(recharge_customer_id, customer_billing)
  end

  if !customer_shipping.nil? && valid_shipping_details(customer_shipping)
    updated_shipping = change_recharge_shipping(recharge_customer_id, customer_shipping)
  end

  return updated_billing && updated_shipping
end

def valid_billing_details(customer_billing)
  return ['billing_first_name', 'billing_last_name', 'billing_address1', 'billing_zip', 'billing_city', 'billing_province', 'billing_country', 'billing_phone'].all? {|s| customer_billing.key? s}
end

def valid_shipping_details(customer_shipping)
  return ['first_name', 'last_name', 'address1', 'zip', 'city', 'province', 'country', 'phone'].all? {|s| customer_shipping.key? s}
end

def change_recharge_billing(recharge_customer_id, customer_billing)
  conn = recharge_connection()
  billing_response = conn.put do |req|
    req.url "/customers/#{recharge_customer_id}"
    req.headers['X-Recharge-Access-Token'] = RECHARGE_API_KEY
    req.headers['Accept'] = 'application/json'
    req.headers['Content-Type'] = 'application/json'
    req.body = customer_billing.to_json
  end

  return billing_response.success?
end

def change_recharge_shipping(recharge_customer_id, customer_shipping)
  conn = recharge_connection()
  customer_address_response = conn.get do |req|
    req.url "/customers/#{recharge_customer_id}/addresses"
    req.headers['X-Recharge-Access-Token'] = RECHARGE_API_KEY
    req.params = { }
  end

  customer_addresses = JSON.parse(customer_address_response.body)['addresses']

  return false if customer_addresses.length > 1

  customer_address = customer_addresses[0]
  update_address_response = conn.put do |req|
    req.url "/addresses/#{customer_address['id']}"
    req.headers['X-Recharge-Access-Token'] = RECHARGE_API_KEY
    req.headers['Accept'] = 'application/json'
    req.headers['Content-Type'] = 'application/json'
    req.body = customer_shipping.to_json
  end

  return update_address_response.success?
end


def calculate_delivery(order, first_order=true)
  if first_order
    order_date = Date.strptime(order['created_at'])
    shipping_title = order['shipping_lines'][0]['title']

    if shipping_title.include?('1-2') || shipping_title.downcase.include?('rush')
      return 2.business_days.after(order_date).to_time.to_i * 1000
    else
      return 5.business_days.after(order_date).to_time.to_i * 1000
    end
  else
    order_date = Date.strptime(order['next_charge_scheduled_at'])
    return 5.business_days.after(order_date).to_time.to_i * 1000
  end
end

def update_recharge_subscription(customer_id, subscription_id, next_subscription_time)
  # time from flex page will be in milliseconds, so convert to seconds before converting to Time obj
  next_sub_delivery = Time.at(next_subscription_time/1000).to_datetime
  next_subscription = 4.business_days.before(next_sub_delivery)
  conn = recharge_connection()

  response = conn.post do |req|
    req.url "/subscriptions/#{subscription_id}/set_next_charge_date"
    req.headers['X-Recharge-Access-Token'] = RECHARGE_API_KEY
    req.headers['Accept'] = 'application/json'
    req.headers['Content-Type'] = 'application/json'
    req.body = { 'date': next_subscription.strftime[0..10] + "00:00:00" }.to_json
  end

  response.success?
end

def skip_recharge_intervals(subscription_data, intervals_skipped)

  # TODO: NEED TO COMPUTE TIME TO ADD, BASED ON interval unit (DAY/WEEK/MONTH) AND interval frequency.
  next_subscription = skip_delivery_until(subscription_data, intervals_skipped)

  conn = recharge_connection()
  response = conn.post do |req|
    req.url "/subscriptions/#{subscription_data['id']}/set_next_charge_date"
    req.headers['X-Recharge-Access-Token'] = RECHARGE_API_KEY
    req.headers['Accept'] = 'application/json'
    req.headers['Content-Type'] = 'application/json'
    req.body = { 'date': next_subscription.strftime[0..10] + "00:00:00" }.to_json
  end

  response.success?
end

def skip_delivery_until(subscription_data, intervals_skipped)
  sub_interval = subscription_data['order_interval_unit']
  sub_frequency = subscription_data['order_interval_frequency'].to_i
  next_charge_date = subscription_data['next_charge_scheduled_at']

  if sub_interval == 'day'
    next_subscription = Date.parse(next_charge_date).to_time.to_i + (sub_frequency * intervals_skipped * 86400)
  elsif sub_interval == 'week'
    next_subscription = Date.parse(next_charge_date).to_time.to_i + (sub_frequency * intervals_skipped * 86400 * 7)
  elsif sub_interval == 'month'
    next_subscription = Date.parse(next_charge_date).to_time.to_i + (sub_frequency * intervals_skipped * 86400 * 30)
  end

  return Time.at(next_subscription).to_datetime
end

def pause_recharge_subscription(customer_id, subscription_id, cancellation_reason, customer_tags)
  # time from flex page will be in milliseconds, so convert to seconds before converting to Time obj
  conn = recharge_connection()

  recharge_response = conn.post do |req|
    req.url "/subscriptions/#{subscription_id}/cancel"
    req.headers['X-Recharge-Access-Token'] = RECHARGE_API_KEY
    req.headers['Accept'] = 'application/json'
    req.headers['Content-Type'] = 'application/json'
    req.body = { 'cancellation_reason': cancellation_reason }.to_json
  end

  shopify_response = nil
  if recharge_response.success?
    updated_tags = customer_tags.sub('Inactive Subscriber', '').sub('Active Subscriber', 'Paused Subscription, Inactive Subscriber')
    shopify_response = update_shopify_customer_tags(customer_id, updated_tags)
  end

  puts "Recharge: #{recharge_response}"
  puts "Shopify: #{shopify_response}"
  recharge_response.success? && !(shopify_response.nil?) && shopify_response.success?
end

def get_recharge_subscription(customer_id, subscription_id)
  # query recharge api for next charge date
  recharge_data = get_recharge_data(customer_id)

  recharge_data.each do |sub|
    return sub if sub['id'].to_s == subscription_id
  end

  return nil
end

def reactivate_recharge_subscription(customer_id, subscription_id, next_subscription_time, customer_tags)
  # time from flex page will be in milliseconds, so convert to seconds before converting to Time obj
  next_sub_delivery = Time.at(next_subscription_time/1000).to_datetime
  next_subscription = 3.business_days.before(next_sub_delivery)
  recharge_conn = recharge_connection()

  activate_response = nil
  activate_response = recharge_conn.post do |req|
    req.url "/subscriptions/#{subscription_id}/activate"
    req.headers['X-Recharge-Access-Token'] = RECHARGE_API_KEY
    req.headers['Accept'] = 'application/json'
    req.headers['Content-Type'] = 'application/json'
    req.body = { }.to_json
  end

  recharge_response = nil
  if !activate_response.nil? && activate_response.success?
    recharge_response = recharge_conn.post do |req|
      req.url "/subscriptions/#{subscription_id}/set_next_charge_date"
      req.headers['X-Recharge-Access-Token'] = RECHARGE_API_KEY
      req.headers['Accept'] = 'application/json'
      req.headers['Content-Type'] = 'application/json'
      req.body = { 'date': next_subscription.strftime[0..10] + "00:00:00" }.to_json
    end
  else
    puts "Failed to reactivate. activate_response: #{activate_response.body}"
  end

  shopify_response = nil
  if !recharge_response.nil? && recharge_response.success?
    updated_tags = customer_tags.sub('Paused Subscription', 'Unpaused Subscription').sub('Inactive Subscriber', 'Active Subscriber')
    shopify_response = update_shopify_customer_tags(customer_id, updated_tags)
  else
    puts "Failed to reactivate. recharge_response: #{recharge_response.body}"
  end

  api_responses = [activate_response, recharge_response, shopify_response]
  !api_responses.include?(nil) && activate_response.success? && recharge_response.success? && shopify_response.success?
end

def update_shopify_customer_tags(customer_id, customer_tags)
  shopify_conn = shopify_connection()
  shopify_response = shopify_conn.put do |req|
    req.url "/admin/customers/#{customer_id}.json"
    req.headers['Accept'] = 'application/json'
    req.headers['Content-Type'] = 'application/json'
    req.body = { "customer": { "id": customer_id, "tags": customer_tags }}.to_json
  end

  return shopify_response
end

def sync_shopify_metadata()
  needs_update = CustomerAction.all.where('customer_actions.shopify_updated = ?', false)
  if needs_update.length == 0
    puts "No shopify accounts need metafield updating..."
  else
    puts "Attempting to update #{needs_update.length} shopify customer records...."
    needs_update.each do |nu|
      update_shopify_customer(nu)
    end
    puts "Done updated attempts for now..."
  end
end

def update_shopify_customer(customer_action)
  action = customer_action.action
  if action == 'paused'
    metadata = { 'key': 'paused', 'namespace': 'subscription', 'value': customer_action.created.to_s, 'value_type': 'string', 'description': customer_action.cancellation_reason }
  elsif action == 'cancelled'
    metadata = { 'key': 'cancelled', 'namespace': 'subscription', 'value':  customer_action.created.to_s, 'value_type': 'string', 'description': customer_action.cancellation_reason }
  elsif action == 'skipped'
    metadata = { 'key': 'skipped', 'namespace': 'subscription', 'value':  customer_action.created.to_s, 'value_type': 'string' }
  elsif action == 'reactivated'
    metadata = { 'key': 'reactivated', 'namespace': 'subscription', 'value':  customer_action.created.to_s, 'value_type': 'string' }
  end

  conn = shopify_connection()
  shopify_response = conn.post do |req|
    req.url "/admin/customers/#{customer_action.shopify_id}/metafields.json"
    req.headers['Accept'] = 'application/json'
    req.headers['Content-Type'] = 'application/json'
    req.body = { 'metafield' => metadata }.to_json
  end

  if shopify_response.success?
    customer_action.shopify_updated = true
    customer_action.save!
  else
    puts "Failed attempt to update Shopify customer: #{shopify_response.body.to_json}"
  end
end

def sync_klaviyo_data()
  return true
end
