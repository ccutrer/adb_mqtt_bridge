module ADB
  class Device
    class SHIELD < Device
      # :asleep, :awake, :dreaming
      attr_reader :wakefulness
      
      def update
        super
        update_attribute(:wakefulness,
          system("dumpsys power | grep mWakefulness=").strip.split("=").last.downcase.to_sym)
      end

      def wake_up
        @shell.puts("dumpsys power | grep mWakefulness=Asleep > /dev/null && input keyevent KEYCODE_POWER")
      end

      def sleep
        @shell.puts("dumpsys power | grep mWakefulness=Asleep > /dev/null || input keyevent KEYCODE_POWER")
      end
    end
  end
end
