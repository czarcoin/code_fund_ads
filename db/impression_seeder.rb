# frozen_string_literal: true

require "benchmark"
require "csv"
require "etc"
require "fileutils"

class ImpressionSeeder
  def self.run(desired_count, months)
    new(desired_count, months).call
  end

  attr_reader :initial_count, :max_count, :gap_count, :months

  def initialize(desired_count, months)
    print "Seeding impressions start...".ljust(48)

    @initial_count = Impression.count
    @max_count = desired_count.to_i.zero? ? 100_000 : desired_count.to_i
    @months = months.to_i.zero? ? 12 : months.to_i
    @months = 4 if @months < 4
    @gap_count = max_count - initial_count
    @gap_count = 0 if @gap_count < 0
    @cores = [@months, cores].min
    @partition_tables = {}

    puts "creating [#{gap_count.to_s.rjust(8)}] new impressions spread over [#{@months}] months using [#{cores}] cpu cores"
    print "".ljust(48)
    puts "...the count is an estimate due to randomness added to mimic real world behavior"

    @publishers = User.publishers.includes(:properties).load
    @campaigns_cache = {}
  end

  def cores
    @cores ||= begin
      cores = Etc.nprocessors - 1
      cores = 1 if cores < 1
      cores
    end
  end

  def max_count_per_core
    (gap_count / cores.to_f).floor
  end

  def call
    if initial_count < max_count
      benchmark = Benchmark.measure {
        dates = [Date.current.beginning_of_month]
        (months - 1).times.each { dates << dates.last.advance(months: -1) }
        chunked_dates = dates.in_groups_of((months / cores.to_f).ceil)
        pids = cores.times.map { |i|
          Process.fork do
            pid_dates = chunked_dates[i]
            max = (max_count_per_core / pid_dates.size.to_f).floor
            pid_dates.each { |date| create_impressions_for_month date.iso8601, max }
          end
        }
        pids.each { |pid| Process.waitpid pid }
      }
    end
    print "Seeding impressions finish...".ljust(48)
    print "verified [#{Impression.count.to_s.rjust(8)}] total impressions".ljust(48)
    puts benchmark
  end

  private

  def incomplete?
    @count < @max
  end

  def build_impression(displayed_at)
    property = @publishers.sample.properties.sample
    campaigns = @campaigns_cache[property.id] ||= Campaign.includes(:user, :creative).for_property(property).load
    campaign = campaigns.select { |c| c.available_on? displayed_at }.sample
    return nil unless campaign
    @count += 1
    impression = Impression.new(
      id: SecureRandom.uuid,
      advertiser_id: campaign.user_id,
      campaign_id: campaign.id,
      campaign_name: campaign.scoped_name,
      property_id: property.id,
      property_name: property.scoped_name,
      ip: rand(6).zero? ? Faker::Internet.ip_v6_address : Faker::Internet.public_ip_v4_address,
      user_agent: Faker::Internet.user_agent,
      country_code: rand(6).zero? ? ENUMS::COUNTRIES["United States"] : ENUMS::COUNTRIES.keys.sample,
      payable: rand(10).zero? ? false : true,
      displayed_at: displayed_at,
      displayed_at_date: displayed_at.to_date,
      clicked_at: rand(100) <= 3 ? displayed_at : nil,
      fallback_campaign: campaign.fallback,
    )
    @partition_tables[impression.partition_table_name] ||= begin
      impression.assure_partition_table!
      true
    end
    impression.attributes
  end

  def build_impressions(displayed_at)
    core_hours = displayed_at.hour.between?(0, 6) || displayed_at.hour.between?(13, 21) ? true : false

    # 3x more likely to have impressions this second during core hours
    unless core_hours
      return [] unless rand(4).zero?
    end

    rand(@max_per_second).times.map {
      build_impression displayed_at
    }.compact
  end

  def build_impressions_for_minute(time)
    displayed_at = Time.new(time.year, time.month, time.day, time.hour, time.min, 0, 0)
    impressions = []
    while incomplete? && displayed_at.min == time.min && displayed_at.sec <= 59
      impressions.concat build_impressions(displayed_at)
      displayed_at = displayed_at.advance(seconds: rand(11))
    end
    impressions
  end

  def build_impressions_for_hour(time)
    displayed_at = Time.new(time.year, time.month, time.day, time.hour, 0, 0, 0)
    impressions = []
    while incomplete? && displayed_at.hour == time.hour && displayed_at.min <= 59
      impressions.concat build_impressions_for_minute(displayed_at)
      displayed_at = displayed_at.advance(minutes: rand(3))
    end
    impressions
  end

  def build_impressions_for_day(date)
    displayed_at = Time.new(date.year, date.month, date.day, 0, 0, 0, 0)
    impressions = []
    while incomplete? && displayed_at.day == date.day && displayed_at.hour <= 23
      impressions.concat build_impressions_for_hour(displayed_at)
      displayed_at = displayed_at.advance(hours: 1)
    end
    impressions
  end

  def create_impressions_for_month(date_string, max)
    @count = 0
    @max = max
    @max_per_second = (max / 1.month.seconds.to_f).ceil * 6
    start_date = Date.parse(date_string).beginning_of_month
    active_date = start_date
    list = []
    error = nil

    benchmark = Benchmark.measure {
      while incomplete? && active_date <= start_date.end_of_month
        list.concat build_impressions_for_day(active_date.to_time)
        active_date = active_date.advance(days: 1)
      end

      csv_path = "/tmp/impressions-#{Process.pid}.csv"
      CSV.open(csv_path, "wb") do |csv|
        list.each { |record| csv << record.values }
      end

      begin
        ActiveRecord::Base.connection.execute "COPY \"impressions\" FROM '#{csv_path}' CSV;"
      rescue => e
        error = e
        puts "Failed to copy #{csv_path} to Postgres! #{e}"
      ensure
        FileUtils.rm_f csv_path
      end
    }

    unless error
      message = "Seeding impressions...".ljust(48)
      message += "created [#{@count}] records with pid: #{Process.pid}".ljust(48)
      message += benchmark.to_s
      puts message
    end
  end
end