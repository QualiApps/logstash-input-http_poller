# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/plugin_mixins/http_client"
require "socket" # for Socket.gethostname
require "manticore"

# This Logstash input plugin allows you to call an HTTP API, decode the output of it into event(s), and
# send them on their merry way. The idea behind this plugins came from a need to read springboot
# metrics endpoint, instead of configuring jmx to monitor my java application memory/gc/ etc.
#
# ==== Example
# Reads from a list of urls and decodes the body of the response with a codec.
# The config should look like this:
#
# [source,ruby]
# ----------------------------------
# input {
#   leshan_poller {
#     urls => {
#       test1 => "http://leshan:8080/api/clients"
#     }
#     request_timeout => 60
#     interval => 60
#     codec => "json"
#     # A hash of request metadata info (timing, response headers, etc.) will be sent here
#     metadata_target => "leshan_poller_metadata"
#   }
# }
#
# output {
#   stdout {
#     codec => rubydebug
#   }
# }
# ----------------------------------

class LogStash::Inputs::LESHAN_Poller < LogStash::Inputs::Base
  include LogStash::PluginMixins::HttpClient

  config_name "leshan_poller"

  default :codec, "json"

  # A Hash of urls in this format : `"name" => "url"`.
  # The name and the url will be passed in the outputed event
  config :urls, :validate => :hash, :required => true

  # How often (in seconds) the urls will be called
  config :interval, :validate => :number, :required => true

  # Define the target field for placing the received data. If this setting is omitted, the data will be stored at the root (top level) of the event.
  config :target, :validate => :string

  # If you'd like to work with the request/response metadata.
  # Set this value to the name of the field you'd like to store a nested
  # hash of metadata.
  config :metadata_target, :validate => :string, :default => '@metadata'

  public
  def register
    @res_devices = Hash[]
    @host = Socket.gethostname.force_encoding(Encoding::UTF_8)

    @logger.info("Registering leshan_poller Input", :type => @type,
                 :urls => @urls, :interval => @interval, :timeout => @timeout)

    setup_requests!
  end

  def stop
    Stud.stop!(@interval_thread) if @interval_thread
  end

  private
  def setup_requests!
    @requests = Hash[@urls.map {|name, url| [name, normalize_request(url)] }]
  end

  private
  def normalize_request(url_or_spec)
    if url_or_spec.is_a?(String)
      res = [:get, url_or_spec]
    elsif url_or_spec.is_a?(Hash)
      # The client will expect keys / values
      spec = Hash[url_or_spec.clone.map {|k,v| [k.to_sym, v] }] # symbolize keys

      # method and url aren't really part of the options, so we pull them out
      method = (spec.delete(:method) || :get).to_sym.downcase
      url = spec.delete(:url)

      # We need these strings to be keywords!
      spec[:auth] = {user: spec[:auth]["user"], pass: spec[:auth]["password"]} if spec[:auth]

      res = [method, url, spec]
    else
      raise LogStash::ConfigurationError, "Invalid URL or request spec: '#{url_or_spec}', expected a String or Hash!"
    end

    validate_request!(url_or_spec, res)
    res
  end

  private
  def validate_request!(url_or_spec, request)
    method, url, spec = request

    raise LogStash::ConfigurationError, "Invalid URL #{url}" unless URI::DEFAULT_PARSER.regexp[:ABS_URI].match(url)

    raise LogStash::ConfigurationError, "No URL provided for request! #{url_or_spec}" unless url
    if spec && spec[:auth]
      if !spec[:auth][:user]
        raise LogStash::ConfigurationError, "Auth was specified, but 'user' was not!"
      end
      if !spec[:auth][:pass]
        raise LogStash::ConfigurationError, "Auth was specified, but 'password' was not!"
      end
    end

    request
  end

  public
  def run(queue)
    @interval_thread = Thread.current
    Stud.interval(@interval) do
      run_once(queue)
    end
  end

  private
  def run_once(queue)
    @requests.each do |name, request|
      device_request(queue, name, request)
    end
  end

  private
  # Retrieves the list of devices
  def device_request(queue, name, request)
    @logger.debug? && @logger.debug("Fetching URL", :name => name, :url => request)
    started = Time.now
    
    client.get(request[1]) { |device_response| device_handle_success(queue, name, request, device_response, Time.now - started)}
  end

  private
  # Retrieves all values of available objects
  def device_handle_success(queue, name, request, device_response, execution_time)
    method, *r_opts = request
    @codec.decode(device_response.body) do |decoded|
      device = decoded.to_hash
      # gets objects
      for object in device['objectLinks'] do
        object_request_async(queue, name, method, *r_opts, request[1], device, object)
      end

      client.execute!
    end
  end

  private
  def object_request_async(queue, name, method, *r_opts, url, device, object)
        *r_opts = url + "/" + device["endpoint"] + object['url']
        obj_request = [method, r_opts[0]]

        started_time = Time.now

        r = client.async.send(method, *r_opts).
          on_success {|response| handle_success(queue, name, obj_request, response, Time.now - started_time)}.
          on_failure {|exception| handle_failure(queue, name, request, exception, Time.now - started_time)
        }

        @res_devices[r.context] = Hash["endpoint", device["endpoint"], "registrationId", device["registrationId"], "registrationDate", device["registrationDate"], "address", device["address"], "objectId", object['objectId'], "objectInstanceId", object["objectInstanceId"]]
  end

  private
  def handle_success(queue, name, request, response, execution_time)
    @codec.decode(response.body) do |decoded|
      event = @target ? LogStash::Event.new(@target => decoded.to_hash ) : decoded
      handle_decoded_event(queue, name, request, response, event, execution_time)
    end
  end

  private
  def handle_decoded_event(queue, name, request, response, event, execution_time)
    apply_metadata(event, name, request, response, execution_time)
    decorate(event)
    event = update_event(event, response.context)
    @res_devices.delete(response.context)
    queue << event
  rescue StandardError, java.lang.Exception => e
    @logger.error? && @logger.error("Error eventifying response!",
                                    :exception => e,
                                    :exception_message => e.message,
                                    :name => name,
                                    :url => request,
                                    :response => response
    )
  end

  private
  # Update event
  def update_event(event, identity)
    event['endpoint'] = get_device_info(identity, 'endpoint')
    event['registrationId'] = get_device_info(identity, 'registrationId')
    event['registrationDate'] = get_device_info(identity, 'registrationDate')
    event['address'] = get_device_info(identity, 'address')
    event['objectId'] = get_device_info(identity, 'objectId')
    event['objectInstanceId'] = get_device_info(identity, 'objectInstanceId')  

  return event
  end

  private
  # Retrieves device info
  def get_device_info(identity, key)
    return @res_devices[identity][key] if @res_devices[identity][key]
  end

  private
  # Beware, on old versions of manticore some uncommon failures are not handled
  def handle_failure(queue, name, request, exception, execution_time)
    event = LogStash::Event.new
    apply_metadata(event, name, request)

    event.tag("_http_request_failure")

    # This is also in the metadata, but we send it anyone because we want this
    # persisted by default, whereas metadata isn't. People don't like mysterious errors
    event["http_request_failure"] = {
      "request" => structure_request(request),
      "name" => name,
      "error" => exception.to_s,
      "backtrace" => exception.backtrace,
      "runtime_seconds" => execution_time
   }

    queue << event
  rescue StandardError, java.lang.Exception => e
      @logger.error? && @logger.error("Cannot read URL or send the error as an event!",
                                      :exception => e,
                                      :exception_message => e.message,
                                      :exception_backtrace => e.backtrace,
                                      :name => name,
                                      :url => request
      )
  end

  private
  def apply_metadata(event, name, request, response=nil, execution_time=nil)
    return unless @metadata_target
    event[@metadata_target] = event_metadata(name, request, response, execution_time)
  end

  private
  def event_metadata(name, request, response=nil, execution_time=nil)
    m = {
        "name" => name,
        "host" => @host,
        "request" => structure_request(request),
      }

    m["runtime_seconds"] = execution_time

    if response
      m["code"] = response.code
      m["response_headers"] = response.headers
      m["response_message"] = response.message
      m["times_retried"] = response.times_retried
    end

    m
  end

  private
  # Turn [method, url, spec] requests into a hash for friendlier logging / ES indexing
  def structure_request(request)
    method, url, spec = request
    # Flatten everything into the 'spec' hash, also stringify any keys to normalize
    Hash[(spec||{}).merge({
      "method" => method.to_s,
      "url" => url,
    }).map {|k,v| [k.to_s,v] }]
  end
end
