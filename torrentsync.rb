require 'rubygems'
require 'nokogiri'
require 'net/http'
#require 'json'
require 'open-uri'
require 'base64'

class Transmission
  def initialize(host, port, user = nil, pass = nil)
    @host = host
    @port = port
    @user = user
    @pass = pass
  end

  def exec(command, arguments)
    sessionid = Net::HTTP.start(@host, @port) do |http|
      res = http.get('/transmission/rpc')
      h = Nokogiri::HTML.parse(res.body)
      h.css('code').text.split.last
    end
    header = {
      'Content-Type' => 'application/json',
    }
    header['X-Transmission-Session-Id'] = sessionid unless sessionid.nil?
    Net::HTTP.start(@host, @port) do |http|
      json = {
        :method => command,
        :arguments => arguments
      }
      res = http.post('/transmission/rpc', json.to_json, header)
      JSON.parse(res.body)
    end
  end

  def list
    exec('torrent-get', {
      :fields => [ :hashString, :id, :name, :totalSize, :haveValid ]
    })
  end

  def add(torrent)
    exec('torrent-add', :metainfo => Base64::encode64(torrent))
  end

  def remove(torrentid, removedata = false)
    exec('torrent-remove', :ids => [torrentid],
        'delete-local-data' => removedata)
  end
end
