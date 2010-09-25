#!/usr/bin/ruby
require 'net/http'
require 'rubygems'
require 'rss'
require 'open-uri'
# gem
#require 'json'
require 'nokogiri'
require File.dirname(__FILE__)+'/torrentsync'
require 'escape'
require 'thread'

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
  @@base_url2 = "http://www.nyaatorrents.org/?page=rss&term="
  @@mutex = Mutex.new

  def initialize(options={})
    @torrent_client = Transmission.new("localhost", 9091)

    @options = {:nodownload => false}
    @options.merge!(options)

    load_cache
    load_config
  end

  # downloads all feeds and processes them
  def fetch_feeds
    threads = []
    @config[:feeds].each do |feed|
      threads << Thread.new(feed) do |feed|
        fetch_feed(feed)
      end
    end
    threads.each { |aThread| aThread.join }
  end


  private

  def fetch_feed(feed)
    items = get_feed(feed, :url)

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
      if @options[:nodownload]
        echo title
        next
      end
      next if @cache.has_key?(feed[:name]) && @cache[feed[:name]].include?(title)
      echo "downloading "+title
      begin
        torrent = get_torrent(link)
        if process_torrent(torrent, feed[:path])
          echo "%s torrent added" % title
          @@mutex.lock
          @cache[feed[:name]] = [] unless @cache.has_key?(feed[:name])
          @cache[feed[:name]] << title
          save_cache
          @@mutex.unlock
          added = true
        end
      rescue Exception => e
        echo e.message
        echo e.backtrace.join("\n")
      end
    end
    echo "%s new torrents not found" % feed[:name] unless added
  end

  # downloads torrent
  def get_torrent(url)
    open(url) do |h|
      h.read
    end
  end

  # adds torrent to transmission
  def process_torrent(torrent, path)
    File.open("/tmp/transmission-rss.torrent", "w") do |h|
      h.write(torrent)
    end
    #path.gsub!(/['"\\\x0!\@\#\$\%\^\&\*\(\)\[\]]/, '\\\\\0')
    #pp path
    answer = @torrent_client.exec('torrent-add', :metainfo => Base64::encode64(torrent), "download-dir" => path)
    ["success", "duplicate torrent"].include?(answer["result"])
  end

  # returns array of fetched items
  def get_feed(feed, url_key)
    echo "fetching %s (%s)" % [feed[:name], feed[url_key]]

    items = []
    #return [{:title => "[Zero-Raws] Kaichou wa Maid-sama! - 15 RAW (TBS 1280x720 x264 AAC).mp4", :link => "http://www.nyaatorrents.org/?page=download&tid=142453"}]
    begin
      open(feed[url_key]) do |h|
        parser = RSS::Parser.parse(h.read, false)
        parser.items.each do |item|
          link = item.link.sub('torrentinfo', 'download')
          link = link.gsub!(/btjunkie.org/, "dl.btjunkie.org") + "/download.torrent" if link.match("http://btjunkie.org/")
          items << {:title => item.title.gsub(/[^\d\w\s,.!\@\#\$%\^&*\()_+\=\-\[\]]/, ''), :link => link}
        end
      end
    rescue OpenURI::HTTPError => e
      raise e if url_key == :url2
      return get_feed(feed, :url2)
    rescue Exception => e
      raise Interrupt.new if e.class == Interrupt
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
    #@cache["Kaichou wa Maid-sama"].delete_at(@cache["Kaichou wa Maid-sama"].index("[Zero-Raws] Kaichou wa Maid-sama! - 15 RAW (TBS 1280x720 x264 AAC).mp4")) pp @cache["Kaichou wa Maid-sama"]
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
          item[:filters][k] = Regexp.new(v, true)
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
          item[:url2] = @@base_url2 + item[:keywords].join("+")
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
