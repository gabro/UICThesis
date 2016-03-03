require 'sinatra/base'
require 'sinatra/twitter-bootstrap'
require 'slim'
require 'json'
require 'mechanize'
require 'treat'
require 'colorize'

include Treat::Core::DSL

def print_entity(e)
  if e.has_children?
    e.children.each do |c|
      print_entity c
    end
  else
    puts e
  end
end

def lookup_table
  return {
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
    RECORD_AUDIO: ["record audio", "record voice", "microphone", "audio"],
    READ_CONTACTS: ["contact list", "address book"],
    CALL_PHONE: ["phone", "phone call", "phone calls"]
  }
end

def extract(privacy_url, permission)  
  d = document privacy_url

  d.apply(:chunk, :segment)

  paragraphs = d.entities_with_type(:paragraph)
  sections = d.entities_with_type(:section)

  sections.each do |s|
    begin
        s.check_hasnt_children
        s.apply(:chunk, :segment)
        pp = s.entities_with_type(:paragraph)
        paragraphs.concat pp
    rescue Treat::Exception
    end
  end

  relevant_sentences = []

  # paragraphs.flatten!

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

class BootstrapApp < Sinatra::Base
  register Sinatra::Twitter::Bootstrap::Assets

  set :server, 'webrick'

  get '/' do
    slim :index
  end

  def playstore
  	"java -jar bin/googleplaycrawler.jar --conf bin/crawler.conf"
  end

  post '/playstore-search' do
    
    package = params[:package]
    package = "com.shopkick.app"

  	permissions = retrieve_permissions package

    puts "found #{permissions.length} permissions for #{package}"

	 	privacy_url = find_privacy_url package

    puts "found privacy policy at url #{privacy_url} for #{package}"

    permissions = permissions.map { |p| {name: p, privacy_related: lookup_table.has_key?(p.to_sym) } }
    puts permissions
	 	{ permissions: permissions , privacy_url: privacy_url }.to_json
  end

  def retrieve_permissions (package_name)
  	results = `#{self.playstore} permissions #{package_name}`
  	permissions = []
  	results.each_line.drop(1).each do |line|
		p = line.strip
		if p.start_with? "android.permission"
			p = p.split(".").last
			permissions << p
		end
  	end
  	permissions
  end

  post '/extract' do
    permission = params[:permission]
    privacy_url = params[:privacy_url]
    
    descriptions = {
      ACCESS_COARSE_LOCATION:
        "Allows the app to know the coarse location of the device.
        The coarse location is computed combining location information deriving from
        the IP address and the cellular towers."
    }

    sentences = extract(privacy_url, permission)
    puts sentence
    { sentences: sentences, description: descriptions[permission.to_sym] }.to_json
  end

 	def find_privacy_url (package_name)
		play_store_url = "https://play.google.com/store/apps/details?id=#{package_name}"
  		privacy_url = nil
    	browser = Mechanize.new
    	browser.follow_meta_refresh = true
    	browser.get(play_store_url) do |page|
    		privacy_link = page.link_with(:text => /Norme sulla privacy/)
        unless privacy_link.nil?
	        	begin
	          		privacy_page = browser.click(privacy_link)
	          		privacy_url = privacy_page.uri.to_s
	        	rescue Mechanize::ResponseCodeError
	        		puts "Error!"
              #TODO: handle error
	        	end
	      	end
    	end
    privacy_url
	end

  post '/playstore-search-autocomplete' do
  	results = `#{self.playstore} search \"#{params[:term]}\"`
  	games = []
  	results.each_line.drop(1).each do |line|
  		title, package = line.split(";")[0..1]
  		games << { title: title, package: package }
  	end
        
    content_type :json
	 { games: games }.to_json
  end

end

BootstrapApp.run!