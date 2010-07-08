#!/usr/bin/ruby
# == Synopsis
#
# transmission-rss: parses feeds from config file and adds them to transmission torrent client
#
# == Usage
#
# transmission-rss [OPTIONS] ... PATH
#
# --help, -h:
#    show help.
#
# --test feed_name, -t feed_name:
#    test run
#
# --download feed_name, -d feed_name:
#    download only specified feed
require 'getoptlong'
require 'rdoc/usage'
require 'net/http'
require 'rubygems'
require 'rss'
require 'open-uri'
require 'pp'
# gem
require 'json'
require 'nokogiri'
require 'torrentsync'
require 'escape'


class Hash
  def symbolize_keys
    inject({}) do |options, (key, value)|
      options[(key.to_sym rescue key) || key] = value
      options
    end
  end

  def symbolize_keys!
    self.replace(self.symbolize_keys)
  end
end


class TransmissionRSS
  @@cache_file = "#{ENV["HOME"]}/.transmission-rss.cache.yaml"
  @@config_file = "#{ENV["HOME"]}/.transmission-rss.config.json"
  @@base_url = "http://pipes.yahoo.com/pipes/pipe.run?_id=06545c5b8595ad700ac035cfe90d3a0d&_render=rss"

  def initialize(options={})
    @torrent_client = Transmission.new("localhost", 9091)

    @options = {:nodownload => false}
    @options.merge!(options)

    load_cache
    load_config
  end

  # downloads all feeds and processes them
  def fetch_feeds
    @config[:feeds].each do |feed|
      echo "fetching %s (%s)" % [feed[:name], feed[:url]]
      items = get_feed(feed[:url])

      items = items.delete_if do |item|
        !feed[:filters].all? {|filter| item[:title].match(filter) }
      end
      # filter all dublicates
      items = items.inject({}) do |result, element|
        result[element[:title]] = element[:link]
        result
      end

      added = false
      items.each do |title,link|
        next if @cache.has_key?(feed[:name]) && @cache[feed[:name]].include?(title)
        if @options[:nodownload]
          echo title
          next
        end
        echo "downloading "+title
        begin
          torrent = get_torrent(link)
          if process_torrent(torrent, feed[:path])
            echo "torrent added"
            @cache[feed[:name]] = [] unless @cache.has_key?(feed[:name])
            @cache[feed[:name]] << title
            save_cache
            added = true
          end
        rescue Exception => e
          echo e.message
          echo e.backtrace.join("\n")
        end
      end
      echo "new torrents not found" unless added
      echo ""
    end
  end


  private

  # downloads torrent
  def get_torrent(url)
    open(url) do |h|
      h.read
    end
  end

  # adds torrent to transmission
  def process_torrent(torrent, path)
    answer = @torrent_client.exec('torrent-add', :metainfo => Base64::encode64(torrent), "download-dir" => path)
    ["success", "duplicate torrent"].include?(answer["result"])
  end

  # returns array of fetched items
  def get_feed(feed_url)
    items = []
    begin
      open(feed_url) do |h|
        parser = RSS::Parser.parse(h.read, false)
        parser.items.each do |item|
          items << {:title => item.title.gsub(/[^\d\w\s,.!\@\#\$%\^&*\()_+\=\-\[\]]/, ''), :link => item.link.sub('torrentinfo', 'download')}
        end
      end
    rescue Interrupt => e
      exit
    rescue Exception => e
      echo e.message
      echo e.backtrace.join("\n")
    end
    items
  end

  def load_cache
    begin
      File.open(@@cache_file, "r") {|f| @cache = Marshal.load(f) } if File.exists?(@@cache_file)
    ensure
      @cache = {} unless @cache
    end
  end

  def save_cache
    File.open(@@cache_file, "w") {|f| Marshal.dump(@cache, f) }
  end

  def load_config
    begin
      File.open(@@config_file, "r") {|f| @config = JSON.parse(f.read) } if File.exists?(@@config_file)
    ensure
      @config = {:defaults => {}, :feeds => []} unless @config
      @config.symbolize_keys!
      @config[:feeds].each do |item|
        item.symbolize_keys!
        # regexp filters
        item[:filters].each_with_index do |v,k|
          item[:filters][k] = Regexp.new(v)
        end
        # target dir
        Dir.mkdir(item[:path]) unless File.exists?(item[:path])
        # feed url
        unless item.has_key?(:url)
          item[:keywords] = item[:name].split(" ") unless item.has_key?(:keywords)
          raise item[:name]+": too many keywords" if item[:keywords].size > 6
          item[:url] = @@base_url
          item[:keywords].each_with_index do |keyword,index|
            item[:url] += "&keyword_"+index.to_s+"="+keyword
          end
        end
      end
      # filter feeds
      @config[:feeds].delete_if {|v| !@options[:filter_feeds].any? {|test| v[:name].start_with?(test) } } if @options[:filter_feeds] && @options[:filter_feeds].size
    end
  end

  def echo(message)
    File.open("/tmp/transmission-rss.log", "a") {|f| f.write(message+"\n") }
    puts message
    #print "\033[32;1m#{message}\33[0m"
  end
end

def notify_exception(e)
  puts e.message
  puts e.backtrace.join("\n")
  %x(/home/morr/scripts/notify --summary "transmission-rss exception" --body "#{e.message.gsub('`', '')}" --icon /usr/share/icons/gnome/scalable/emblems/emblem-important.svg)#
end


opts = GetoptLong.new(
  [ '--download', '-d', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--help', '-h', GetoptLong::NO_ARGUMENT ],
  [ '--test', '-t', GetoptLong::REQUIRED_ARGUMENT ]
)

test_run = false
download_feed = nil

opts.each do |opt, arg|
  case opt
    when '--help'
      RDoc::usage

    when '--test'
      download_feed = arg.to_s
      test_run = true

    when '--download'
      download_feed = arg.to_s
  end
end


begin
  loader = TransmissionRSS.new(:nodownload => test_run, :filter_feeds => [download_feed]) if download_feed
  loader = TransmissionRSS.new unless download_feed
  loader.fetch_feeds
rescue Exception => e
  notify_exception(e)
end
