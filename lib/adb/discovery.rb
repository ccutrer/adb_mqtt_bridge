require 'dnssd'

module ADB
  module Discovery
    class << self
      def discover
        DNSSD.browse!('_adb._tcp') do |reply|
          next unless reply.flags.add?
          if reply.name =~ /^adb-(.+)$/
            serial = $1

            yield serial, reply.resolve.target
          end
        end
      end
    end
  end
end
