require 'cgi'
require 'time'
require 'openssl'
require 'rest-client'
require 'json'

require 'coinkite/version'

require 'coinkite/errors/api_connection_error'
require 'coinkite/errors/coinkite_error'

module Coinkite
  class Client
    DEFAULT_CA_BUNDLE_PATH = File.dirname(__FILE__) + '/data/ca-certificates.crt'

    def initialize(api_key, api_secret)
      @api_key = api_key
      @api_secret = api_secret
      @api_base = 'https://api.coinkite.com'
      @ssl_bundle_path  = DEFAULT_CA_BUNDLE_PATH
    end

    def api_url(url='')
      @api_base + url
    end

    def request(method, endpoint, params={}, headers={})
      unless api_key ||= @api_key
        raise AuthenticationError.new('No API key provided. ' +
          'Set your API key using "Coinkite.api_key = <API-KEY>". ' +
          'You can generate API keys from the Coinkite web interface. ')
      end

      url = api_url(endpoint)

      case method.to_s.downcase.to_sym
      when :get, :head, :delete
        url += "#{URI.parse(url).query ? '&' : '?'}#{uri_encode(params)}" if params && params.any?
        payload = nil
      else
        payload = JSON.encode(params.fetch('_data', params))
        headers['Content-Type'] = 'application/json'
      end

      request_opts = {}
      request_opts.update(:verify_ssl => OpenSSL::SSL::VERIFY_PEER,
                          :ssl_ca_file => @ssl_bundle_path,
                          :headers => request_headers(endpoint).update(headers),
                          :method => method, :open_timeout => 30,
                          :payload => payload, :url => url, :timeout => 80)

      begin
        response = RestClient::Request.execute(request_opts)
      rescue SocketError => e
        handle_restclient_error(e)
      rescue NoMethodError => e
        # Work around RestClient bug
        if e.message =~ /\WRequestFailed\W/
          e = APIConnectionError.new('Unexpected HTTP response code')
          handle_restclient_error(e)
        else
          raise
        end
      rescue RestClient::ExceptionWithResponse => e
        if rcode = e.http_code and rbody = e.http_body
          if rcode == 429 and rbody.has_key?("wait_time")
            sleep(rbody.wait_time)
            retry
          else
            handle_api_error(rcode, rbody)
          end
        else
          handle_restclient_error(e)
        end
      rescue RestClient::Exception, Errno::ECONNREFUSED => e
        handle_restclient_error(e)
      end

      JSON.parse(response.body)
    end

    def uri_encode(params)
      params.map { |k,v| "#{k}=#{url_encode(v)}" }.join('&')
    end

    def url_encode(key)
      URI.escape(key.to_s, Regexp.new("[^#{URI::PATTERN::UNRESERVED}]"))
    end

    def handle_restclient_error(e)
      case e
      when RestClient::ServerBrokeConnection, RestClient::RequestTimeout
        message = "Could not connect to Coinkite (#{@api_base}). " +
          "Please check your internet connection and try again. " +
          "If this problem persists, you should check Coinkite's service status at " +
          "https://twitter.com/Coinkite, or let us know at support@coinkite.com."

      when RestClient::SSLCertificateNotVerified
        message = "Could not verify Coinkite's SSL certificate. " +
          "Please make sure that your network is not intercepting certificates. " +
          "(Try going to https://api.coinkite.com in your browser.) " +
          "If this problem persists, let us know at support@coinkite.com."

      when SocketError
        message = "Unexpected error communicating when trying to connect to Coinkite. " +
          "You may be seeing this message because your DNS is not working. " +
          "To check, try running 'host coinkite.com' from the command line."

      else
        message = "Unexpected error communicating with Coinkite. " +
          "If this problem persists, let us know at support@coinkite.com."

      end

      raise APIConnectionError.new(message + "\n\n(Network error: #{e.message})")
    end

    def handle_api_error(rcode, rbody)
      case rcode
      when 400
        raise CoinkiteError.new(rbody)
      when 404
        raise CoinkiteError.new(rbody)
      else
        raise CoinkiteError.new(rbody)
      end
    end

    def make_signature(endpoint, force_ts=nil)
      ts = force_ts || Time.now.utc.iso8601
      data = endpoint + '|' + ts
      hmac = OpenSSL::HMAC.hexdigest(OpenSSL::Digest::Digest.new('SHA256'), @api_secret, data)

      return hmac, ts
    end

    def request_headers(endpoint, force_ts=nil)
      signature, timestamp = make_signature(endpoint, force_ts)

      {
        'X-CK-Key' => @api_key,
        'X-CK-Timestamp' => timestamp,
        'X-CK-Sign' => signature,
        'User-Agent' => "Coinkite/v1 RubyBindings/#{Coinkite::VERSION}"
      }
    end

    def get(endpoint)
      request('GET', endpoint)
    end

    def get_accounts
      get('/v1/my/accounts')["results"]
    end

    def get_detail(refnum)
      get("/v1/detail/#{refnum}")["detail"]
    end

    def get_balance(account)
      get("/v1/account/#{account}")["account"]
    end
  end
end
