require 'eventmachine'

module Repp
  module Handler
    class Shell
      module KeyboardHandler
        include EM::Protocols::LineText2
        def initialize(app) @app = app.new; end
        def receive_line(data)
          reply_to = /@\w+/.match(data)&.[](1)
          message = Event::Receive.new(type: :message, body: data, reply_to: reply_to, bot?: false)
          res = @app.call(message)
          if res.any?
            $stdout.puts res.first
          end
        end
      end

      def self.run(app, options = {})
        yield self if block_given?

        EM.run { EM.open_keyboard(KeyboardHandler, app) }
      end

      def self.stop
        EM.run { EM.stop }
      end
    end
  end
end
