require "socket"
require "ipaddr"
require 'excon'

# Determine the final endpoint for a Web URI, following redirects
class FinalDestination

  attr_reader :status

  def initialize(url, opts = nil)
    @uri = URI(url) rescue nil
    @opts = opts || {}
    @opts[:max_redirects] ||= 5
    @opts[:lookup_ip] ||= lambda do |host|
      begin
        IPSocket::getaddress(host)
      rescue SocketError
        nil
      end
    end
    @limit = @opts[:max_redirects]
    @status = :ready
  end

  def redirected?
    @limit < @opts[:max_redirects]
  end

  def request_headers
    { "User-Agent" => "Mozilla/5.0 (Windows NT 6.2; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.36",
      "Accept" => "text/html",
      "Host" => @uri.hostname }
  end

  def resolve
    if @limit < 0
      @status = :too_many_redirects
      return nil
    end

    return nil unless validate_uri
    headers = request_headers
    head = Excon.head(@uri.to_s, read_timeout: 20, headers: headers)

    # If the site does not allow HEAD, just try the url
    return @uri if head.status == 405

    if head.status == 200
      @status = :resolved
      return @uri
    end

    location = FinalDestination.header_for(head, 'location')
    if location
      location = "#{@uri.scheme}://#{@uri.host}#{location}" if location[0] == "/"
      @uri = URI(location) rescue nil
      @limit -= 1
      return resolve
    end

    nil
  end

  def validate_uri
    validate_uri_format && is_public?
  end

  def validate_uri_format
    return false unless @uri
    return false unless ['https', 'http'].include?(@uri.scheme)

    if @uri.scheme == 'http'
      return @uri.port == 80
    elsif @uri.scheme == 'https'
      return @uri.port == 443
    end

    false
  end

  def is_public?
    return false unless @uri && @uri.host

    address_s = @opts[:lookup_ip].call(@uri.hostname)
    return false unless address_s

    address = IPAddr.new(address_s)
    private_match = FinalDestination.private_ranges.any? {|r| r === address }

    if private_match
      @status = :invalid_address
      return false
    end

    true
  end

  def self.private_ranges
    @private_ranges ||= [
      IPAddr.new('127.0.0.1'),
      IPAddr.new('172.16.0.0/12'),
      IPAddr.new('192.168.0.0/16'),
      IPAddr.new('10.0.0.0/8'),
      IPAddr.new('fc00::/7')
    ]
  end

  def self.lookup_ip(host)
    IPSocket::getaddress(host)
  end

  def self.header_for(head, name)
    header = head.headers.detect do |k, _|
      name == k.downcase
    end
    header[1] if header
  end
end
