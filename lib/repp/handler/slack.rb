module Repp
  module Handler
    class Slack
      require 'slack-ruby-client'

      REPLY_REGEXP = /<@(\w+?)>/

      class SlackReceive < Event::Receive
        interface :channel, :user, :type, :ts, :reply_to

        def bot?; !!@is_bot;  end
        def bot=(switch); @is_bot = switch; end
      end

      class SlackMessageHandler
        attr_reader :client, :web_client, :app
        def initialize(client, web_client, app)
          @client = client
          @web_client = web_client
          @app = app
        end

        def users(refresh = false)
          @users = get_users if refresh
          @users ||= get_users
        end

        def handle
          client.on :message do |message|
            res, receive = process_message(message)
            process_trigger(res, receive)
          end

          client.start!
        end

        def process_message(message)
          receive = if message.instance_of?(Event::Trigger)
                      message
                    else
                      reply_to = (message.text || "").scan(REPLY_REGEXP).map do |node|
                        user = users.find { |u| u.id == node.first }
                        user ? user.name : nil
                      end

                      from_user = users.find { |u| u.id == message.user } || users(true).find { |u| u.id == message.user }

                      receive = SlackReceive.new(
                        body: message.text,
                        channel: message.channel,
                        user: from_user,
                        type: message.type,
                        ts: message.ts,
                        reply_to: reply_to.compact
                      )

                      receive.bot = (message['subtype'] == 'bot_message' || from_user.nil? || from_user['is_bot'])
                      receive
                    end

          res = app.call(receive)

          receive = message.original if message.instance_of?(Event::Trigger)
          if res.first
            channel_to_post = res.last && res.last[:channel] || receive.channel
            attachments = res.last && res.last[:attachments]
            web_client.chat_postMessage(text: res.first, channel: channel_to_post, as_user: true, attachments: attachments)
          end
          [res, receive]
        end

        def process_trigger(res, receive)
          if res[1][:trigger]
            payload = res[1][:trigger][:payload]
            res[1][:trigger][:names].each do |name|
              trigger = Event::Trigger.new(body: name, payload: payload, original: receive)
              Thread.new do
                trigger_res, _ = process_message(trigger)
                process_trigger(trigger_res, receive)
              end
            end
          end
        end

        private

        def get_users
          response = @web_client.users_list
          members = response.members
          while response.response_metadata.next_cursor != ''
            response = @web_client.users_list(cursor: response.response_metadata.next_cursor)
            members.concat(response.members)
          end
          members
        end

      end

      class << self
        def run(app, options = {})
          yield self if block_given?

          ::Slack.configure do |config|
            config.token = detect_token
          end
          @client = ::Slack::RealTime::Client.new
          @web_client = ::Slack::Web::Client.new

          application = app.new
          @ticker = Ticker.task(application) do |res|
            if res.first
              if res.last && res.last[:dest_channel]
                channel_to_post = res.last[:dest_channel]
                attachments = res.last[:attachments]
                @web_client.chat_postMessage(text: res.first, channel: channel_to_post, as_user: true, attachments: attachments)
              else
                message = "Need 'dest_to:' option to every or cron job like:\n" +
                  "every 1.hour, dest_to: 'channel_name' do"
                $stderr.puts(message)
              end
            end
          end
          @ticker.run!
          handler = SlackMessageHandler.new(@client, @web_client, application)
          handler.handle
        end

        def stop!
          @client.stop!
        end

        private

        def detect_token
          return ENV['SLACK_TOKEN'] if ENV['SLACK_TOKEN']
          token_file = "#{ENV['HOME']}/.slack/token"
          return File.read(token_file).chomp if File.exist?(token_file)
          fail "Can't find Slack token"
        end
      end
    end
  end
end
