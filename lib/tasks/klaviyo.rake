namespace :klaviyo do
  desc 'Unsubscribe from Klaviyo SMS every contact with sms_opted_out_at (e.g. after an import). Usage: rails "klaviyo:sync_sms_opt_outs[ACCOUNT_ID]"'
  task :sync_sms_opt_outs, [:account_id] => :environment do |_task, args|
    client = Klaviyo::Client.new(GlobalConfigService.load('KLAVIYO_PRIVATE_API_KEY', nil))
    numbers = Account.find(args[:account_id]).contacts
                     .where("custom_attributes ? 'sms_opted_out_at'").where.not(phone_number: [nil, ''])
                     .distinct.pluck(:phone_number)
    numbers.each_slice(100).with_index(1) do |batch, index|
      client.unsubscribe_sms(phone_numbers: batch)
      puts "#{[index * 100, numbers.size].min} / #{numbers.size}"
      sleep 0.2 # stays under Klaviyo's 750 calls/minute
    end
    puts "Unsubscribed #{numbers.size} numbers from Klaviyo SMS"
  end
end
