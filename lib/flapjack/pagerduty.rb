#!/usr/bin/env ruby

require 'eventmachine'
# the redis/synchrony gems need to be required in this particular order, see
# the redis-rb README for details
require 'hiredis'
require 'em-synchrony'
require 'em-synchrony/em-http'
require 'redis/connection/synchrony'
require 'redis'

require 'yajl/json_gem'

require 'flapjack/data/entity_check'
require 'flapjack/pikelet'

module Flapjack

  class Pagerduty

    include Flapjack::Pikelet

    def initialize(opts = {})
      super()
      self.bootstrap

      @config = opts[:config] ? opts[:config].dup : {}
      logger.debug("New Pagerduty pikelet with the following options: #{opts.inspect}")

      @redis = opts[:redis]
      @redis_config = opts[:redis_config]
      @redis_adhoc = Redis.new(@redis_config.merge(:driver => 'synchrony'))

      @pagerduty_events_api_url = 'https://events.pagerduty.com/generic/2010-04-15/create_event.json'
      @sem_pagerduty_acks_running = 'sem_pagerduty_acks_running'
    end

    def send_pagerduty_event(event)
      options  = { :body => Yajl::Encoder.encode(event) }
      http = EM::HttpRequest.new(@pagerduty_events_api_url).post(options)
      response = Yajl::Parser.parse(http.response)
      status   = http.response_header.status
      logger.debug "send_pagerduty_event got a return code of #{status.to_s} - #{response.inspect}"
      return status, response
    end

    def test_pagerduty_connection
      noop = { "service_key"  => "11111111111111111111111111111111",
               "incident_key" => "Flapjack is running a NOOP",
               "event_type"   => "nop",
               "description"  => "I love APIs with noops." }
      code, results = send_pagerduty_event(noop)
      puts results.inspect
      return true if code == 200 && results['status'] =~ /success/i
      logger.error "Error: test_pagerduty_connection: API returned #{code.to_s} #{results.inspect}"
      return false
    end

    # this should be moved to a checks data model perhaps
    def unacknowledged_failing_checks
      failing_checks = @redis_adhoc.zrange('failed_checks', '0', '-1')
      if not failing_checks.class == Array
        @logger.error("redis.zrange returned something other than an array! Here it is: " + failing_checks.inspect)
      end
      ufc = failing_checks.find_all {|check|
        not @redis_adhoc.exists(check + ':unscheduled_maintenance')
      }
      @logger.debug "found unacknowledged failing checks as follows: " + ufc.join(', ')
      return ufc
    end

    def pagerduty_acknowledged?(opts)
      subdomain   = opts[:subdomain]
      username    = opts[:username]
      password    = opts[:password]
      check       = opts[:check]

      url = 'https://' + subdomain + '.pagerduty.com/api/v1/incidents'
      query = { 'fields'       => 'incident_number,status',
                'since'        => (Time.new.utc - (60*60*24*7)).iso8601,
                'until'        => (Time.new.utc + (60*60*24)).iso8601,
                'incident_key' => check,
                'status'       => 'acknowledged' }

      options = { :head  => { 'authorization' => [username, password] },
                  :query => query }

      http = EM::HttpRequest.new(url).get(options)

      begin
        response = Yajl::Parser.parse(http.response)
      rescue Yajl::ParseError
        @logger.error("failed to parse json from a post to #{url} ... response headers and body follows...")
        @logger.error(http.response_header.inspect)
        @logger.error(http.response)
      end
      status   = http.response_header.status

      if response['incidents'].length > 0
        return true
      else
        return false
      end
    end

    def catch_pagerduty_acks

      if @redis_adhoc.get(@sem_pagerduty_acks_running) == 'true'
        logger.debug("skipping looking for acks in pagerduty as this is already happening")
        return
      end

      @redis_adhoc.set(@sem_pagerduty_acks_running, 'true')
      @redis_adhoc.expire(@sem_pagerduty_acks_running, 300)

      logger.debug("looking for acks in pagerduty for unack'd problems")

      unacknowledged_failing_checks.each {|check|
        entity_check = Flapjack::Data::EntityCheck.for_event_id(check, { :redis => @redis_adhoc } )
        pagerduty_credentials = entity_check.pagerduty_credentials

        options = pagerduty_credentials.merge(:check => check)

        if pagerduty_acknowledged?(options)
          @logger.debug "#{check} is acknowledged in pagerduty, creating flapjack acknowledgement"
          entity_check.create_acknowledgement(:summary => "Acknowledged on PagerDuty")
        else
          @logger.debug "#{check} is not acknowledged in pagerduty"
        end
      }
      # TODO: use a redis key for this with an expiry
      @catch_pagerduty_acks_running = false
      @redis_adhoc.del(@sem_pagerduty_acks_running)
    end

    def add_shutdown_event
      r = ::Redis.new(@redis_config)
      r.rpush(@config['queue'], JSON.generate('notification_type' => 'shutdown'))
      r.quit
    end

    def main
      logger.debug("pagerduty gateway - commencing main method")
      raise "Can't connect to the pagerduty API" unless test_pagerduty_connection

      # TODO: only clear this if there isn't another pagerduty gateway instance running
      # or better, include on instance ID in the semaphore key name
      @redis_adhoc.del(@sem_pagerduty_acks_running)

      EM::Synchrony.add_periodic_timer(10) do
        catch_pagerduty_acks
      end

      queue = @config['queue']
      events = {}

      until should_quit?
          logger.debug("pagerduty gateway is going into blpop mode on #{queue}")
          events[queue] = @redis.blpop(queue)
          event         = Yajl::Parser.parse(events[queue][1])
          type          = event['notification_type']
          logger.debug("pagerduty notification event popped off the queue: " + event.inspect)
          if 'shutdown'.eql?(type)
            # do anything in particular?
          else
            event_id      = event['event_id']
            entity, check = event_id.split(':')
            state         = event['state']
            summary       = event['summary']
            address       = event['address']

            case type.downcase
            when 'acknowledgement'
              maint_str      = "has been acknowledged"
              pagerduty_type = 'acknowledge'
            when 'problem'
              maint_str      = "is #{state.upcase}"
              pagerduty_type = "trigger"
            when 'recovery'
              maint_str      = "is #{state.upcase}"
              pagerduty_type = "resolve"
            end

            message = "#{type.upcase} - \"#{check}\" on #{entity} #{maint_str} - #{summary}"

            pagerduty_event = { :service_key  => address,
                                :incident_key => event_id,
                                :event_type   => pagerduty_type,
                                :description  => message }

            send_pagerduty_event(pagerduty_event)

          end
      end
    end

  end
end

