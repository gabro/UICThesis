require 'benchmark'
require 'mechanize'
require 'treat'
include Treat::Core::DSL

require 'ruby-progressbar'
require 'celluloid/autostart'
require 'colorize'

require 'data_mapper'

DataMapper::setup(:default, "sqlite3://#{Dir.pwd}/apps.db")
class AndroidApp
  include DataMapper::Resource

  property :package_name,           String,   key: true
  property :title,                  String
  property :privacy_url,            Text
  property :score,                  Float,    default: 42.0
  property :privacy_url_unavailble, Boolean,  default: false
  property :score_unavailble,       Boolean,  default: false

  def to_s
    self.package_name
  end
end
DataMapper.finalize.auto_upgrade!

class ScorerActor
  include Celluloid

  def initialize
    @app = nil
  end

  def lookup_table
    {
      INTERNET: ["ip-address", "advertisement"],
      ACCESS_WIFI_STATE: ["mac address", "mac", "ip-address", "ip address"],
      READ_PHONE_STATE: ["device ID", "phone number", "incoming calls"],
      READ_EXTERNAL_STORAGE: ["storage", "sd card", "read data"],
      WRITE_EXTERNAL_STORAGE: ["storage", "sd card", "read data", "write data"],
      GET_ACCOUNTS: ["facebook account", "user name", "gmail account", "google plus account"],
      ACCESS_COARSE_LOCATION: ["IP based location", "location", "location services", "geo-location", "geographic location", "network-based location"],
      ACCESS_FINE_LOCATION: ["gps", "location", "location services", "geo-location", "geographic location"],
      GET_TASKS: ["system tasks", "system processes", "open applications"],
      READ_LOGS: ["system logs", "logs"],
      RECORD_AUDIO: ["record audio", "record voice", "microphone"],
      READ_CONTACTS: ["contact list", "address book"],
      CALL_PHONE: ["phone", "phone call", "phone calls"]
    }
  end

  def extract(privacy_url, permission)
    d = document privacy_url

    d.apply(:chunk, :segment)

    paragraphs = d.entities_with_type(:paragraph)

    relevant_sentences = []

    paragraphs.each do |p|
      sentences = p.entities_with_type(:sentence)
      words = lookup_table[permission.to_sym]
      if (!words.nil?)
        words.each do |word|
          sentences.to_a.select{|s| s.to_s.include? word}.each do |s|
            relevant_sentences << s.to_s
          end
        end
      end
    end

    relevant_sentences.uniq
  end

  def playstore
      "java -jar bin/googleplaycrawler.jar --conf bin/crawler.conf"
  end

  def retrieve_permissions
    results = `#{playstore} permissions #{@app.package_name}`
    permissions = []
    results.each_line.drop(1).each do |line|
    p = line.strip
    if p.start_with? "android.permission"
      p = p.split(".").last
      permissions << p
    end
    end
    permissions.select{|p| lookup_table.has_key?(p.to_sym)}
  end

  def find_privacy_url
    if @app.privacy_url_unavailble?
      nil
    elsif !@app.privacy_url.nil?
      @app.privacy_url
    else 
      privacy_url = nil
      begin
        play_store_url = "https://play.google.com/store/apps/details?id=#{@app.package_name}"
        browser = Mechanize.new
        browser.follow_meta_refresh = true
        browser.get(play_store_url) do |page|
          privacy_link = page.link_with(:text => / Privacy Policy /)
            if privacy_link.nil?
              @app.privacy_url_unavailble = true
            else
              privacy_page = browser.click(privacy_link)
              privacy_url = privacy_page.uri.to_s
            end
        end
      rescue Exception
        privacy_url = nil
      end
      @app.privacy_url = privacy_url
      @app.save
      @app.privacy_url
    end
  end

  def score (app)
    @app = app
    unless @app.score == 42.0
      return @app.score
    end
    permissions = retrieve_permissions
    privacy_url = find_privacy_url
    if privacy_url.nil?
      @app.score_unavailble = true
      @app.save
      raise ScorerError, "Couldn't compute score for #{@app.package_name}" 
    else
      score = permissions.inject(0) do |sum, p|
        begin
          sentences = extract(privacy_url, p)
          if sentences.empty?
            sum += score_for_permission(p)
          end
          sum
        rescue Exception
          @app.score_unavailble = true
          @app.save
          raise ScorerError, "Couldn't compute score for #{@app.package_name}" 
        end
      end
      begin
        @app.score = score.to_f / permissions.length
        @app.save
      rescue FloatDomainError
        @app.score = 42
        @app.save
      end
      @app.score
    end
  end

  def score_for_permission (permission)
    { INTERNET: 3,
      ACCESS_WIFI_STATE: 1,
      READ_PHONE_STATE: 3,
      READ_EXTERNAL_STORAGE: 2,
      WRITE_EXTERNAL_STORAGE: 2,
      GET_ACCOUNTS: 3,
      ACCESS_COARSE_LOCATION: 3,
      ACCESS_FINE_LOCATION: 3,
      GET_TASKS: 1,
      READ_LOGS: 1,
      RECORD_AUDIO: 2,
      READ_CONTACTS: 3,
      CALL_PHONE: 2,
    }[permission.to_sym]
  end
end

class ScorerError < StandardError
end

# module Enumerable
#   def peach(lambda = nil, &block)
#     futures = map do |elem|
#       unless lambda.nil?
#         lambda.call(elem)
#       end
#       Celluloid::Future.new(elem, &block)
#     end
#     futures.each { |future| future.value }
#   end
# end

Celluloid.logger = nil

if ARGV.length == 0
  results = File.new("results", "w")

  scorer_pool = ScorerActor.pool(size: 5)
  if AndroidApp.all.length == 0
    File.readlines("apps.txt").each do |app|
      AndroidApp.first_or_create({package_name: app.chomp}).save
    end
  end

  scheduling_bar = ProgressBar.create(
    :title => "completed",
    :total => AndroidApp.all.count,
    :format => ' Scheduling... %a |%B| %p%% %t',
    :length => 80)

  scored_bar = ProgressBar.create(
    :title => "completed",
    :total => AndroidApp.all.count,
    :format => ' Scoring... %a |%B| %p%% %t',
    :length => 80)


  futures = AndroidApp.all.map do |app|
    scheduling_bar.increment
    scheduling_bar.log "Starting scoring for #{app.package_name}"
    [app, scorer_pool.future.score(app)]
  end

  results = File.new("results", "w")
  futures.each do |entry|
    scored_bar.increment
    app, future = entry
    begin
      score = future.value
      results.puts "#{app}: #{score}"
      scored_bar.log "Scored #{app}: #{score}".green
    rescue ScorerError => err
      results.puts "#{app}: NA"
      scored_bar.log err.message.red
    end
  end
  results.close
elsif ARGV.length == 1
  scorer = ScorerActor.new
  package_name = ARGV.first.chomp
  future_score = scorer.future.score AndroidApp.first_or_create({package_name: package_name}) 
  puts "Score #{future_score.value}"
else 
  puts "Wrong number of arguments. Expected 0 or 1, given #{ARGV.length}"
end
