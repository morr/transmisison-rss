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
require 'json/ext'
require File.dirname(__FILE__)+'/transmission-rss'
require 'pp'
require 'ap'

def notify_exception(e)
  puts e.message
  puts e.backtrace.join("\n")
  %x(/home/morr/scripts/notify --summary "transmission-rss exception" --body "#{e.message.gsub('`', '')}" --icon /usr/share/icons/gnome/scalable/emblems/emblem-important.svg)#
end

trap("INT") do
  Thread.main.kill
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

threads = {}
Thread.abort_on_exception = true
threads[:rss] = Thread.new do
  puts "rss thread started"

  while true
    begin
      loader = TransmissionRSS.new(:nodownload => test_run, :filter_feeds => [download_feed]) if download_feed
      loader = TransmissionRSS.new unless download_feed
      loader.fetch_feeds
    rescue Exception => e
      exit if e.class == Interrupt
      notify_exception(e)
    end
    puts "done"
    sleep(60*30)
  end
end


threads[:conky] = Thread.new do
  puts "conky thread started"

  while true
    torrents = []
    begin
      torrent_client = Transmission.new("localhost", 9091)
      result = torrent_client.exec("torrent-get", :fields => [ "name", "peersGettingFromUs", "peersSendingToUs", "status", "isFinished", "downloadedEver", "totalSize", "uploadRatio", "rateDownload", "rateUpload" ])

      torrents = result["arguments"]["torrents"].
        sort_by {|item| (item["status"] == 4 ? 9999999999999 : 0)+item["rateUpload"] }.
        reverse.
        select {|item| item["status"] == 4 || item["rateUpload"] != 0 }.
        slice(0, 12).
        sort_by {|item| (item["status"] == 4 ? "a" : "b")+(item["name"].sub(/^\[.*?\][_ ]*/, '')) }
    rescue
    ensure
    end

    File.open("/tmp/transmission.json", "w") do |h|
      h.write(torrents.to_json)
    end
    sleep(3)
  end
end

threads.each {|key,thread| thread.join }
