require 'io/wait'

module ADB
  class Device
    autoload :SHIELD, 'adb/device/shield'

    class << self
      def devices
        lines = `adb devices -l`.split("\n")
        raise "could not get device list" unless $?.success?

        # first line is header
        lines.shift
        lines.map { |l| l.split(" ").first }
      end

      def create(adb_serial, cb = nil)
        adb = IO.popen("adb -s #{adb_serial} shell", "w+")

        adb.puts("getprop ro.product.name")
        product_name = adb.gets.strip

        klass = case product_name
        when 'darcy'; SHIELD
        else; self
        end

        klass.new(adb, adb_serial, cb)
      end
    end

    PLAYBACK_STATES = {
      0 => nil,
      1 => :stopped,
      2 => :paused,
      3 => :playing,
      4 => :fast_forwarding,
      5 => :rewinding,
      6 => :buffering,
      7 => :error,
      8 => :connecting,
      9 => :skipping_to_previous,
      10 => :skipping_to_next,
      11 => :skipping_to_queue_item,
    }.freeze

    attr_reader :adb_serial
    attr_reader :serialno,
      :device_name,
      :foreground_app,
      :current_window,
      :playback_state,
      :playback_position,
      :playback_speed,
      :playback_actions

    def update
      system("dumpsys window windows | grep mCurrentFocus=") =~
        /^  mCurrentFocus=Window{[0-9a-f]+ u0 ([a-zA-Z0-9.]+)\/([a-zA-Z0-9.]+)}\n$/
      update_attribute(:foreground_app, $1)
      update_attribute(:current_window, $2)

      playback_state = system("dumpsys media_session | grep state=PlaybackState")
      playback_state = playback_state.match(/^      state=PlaybackState {(.+)}/)[1]
      playback_state = playback_state.split(", ").map { |kv| kv.split("=", 2) }.to_h
      state = PLAYBACK_STATES[playback_state['state'].to_i]
      update_attribute(:playback_state, state)
      position = playback_state['position'].to_f / 1000
      if state == :playing
        now = system("cat /proc/uptime").to_f
        position += now - playback_state['updated'].to_i / 1000.0
      end
      update_attribute(:playback_position, position)
      update_attribute(:playback_speed, playback_state['speed'].to_f)
      actions = []
      action_flags = playback_state['actions'].to_i
      PLAYBACK_ACTIONS.each do |(flag, sym)|
        actions << sym if (action_flags & flag) == flag
      end
      update_attribute(:playback_actions, actions)
    end

    # see https://developer.android.com/reference/android/view/KeyEvent
    def keyevent(key)
      key = "KEYCODE_#{key.upcase}" if key.is_a?(Symbol)
      @adb.puts("input keyevent #{key}")
    end

    def close
      @adb.close
    end

    SENTINEL = "COMMAND COMPLETE"

    def system(command)
      @adb.puts("#{command}; echo #{SENTINEL}")
      result = +''
      loop do
        result.concat(@adb.readpartial(4096))
        break if result.end_with?("#{SENTINEL}\n")
      end
      result = result[0..-(SENTINEL.length + 2)]
      result
    end

    private

    PLAYBACK_ACTIONS = {
      1 => :stop,
      2 => :pause,
      4 => :play,
      8 => :rewind,
      16 => :skip_to_previous,
      32 => :skip_to_next,
      64 => :fast_forward,
      128 => :set_rating,
      256 => :seek_to,
      512 => :play_pause,
      1024 => :play_from_media_id,
      2048 => :play_from_search,
      4096 => :skip_to_queue_item,
      8192 => :play_from_uri,
      16384 => :prepare,
      32768 => :prepare_from_media_id,
      65536 => :prepare_from_search,
      131072 => :prepare_from_uri,
    }.freeze
    private_constant :PLAYBACK_ACTIONS

    def initialize(adb, adb_serial, cb)
      @adb = adb
      @adb_serial = adb_serial
      @cb = cb

      @serialno = system("getprop ro.serialno").strip

      device_name = system("dumpsys settings | grep name:device_name")[0..-2]
      fields = []
      device_name.split(" ").each do |field|
        unless field.include?(':')
          fields.last[-1] += ' ' + field
          next
        end

        fields << field.split(':', 2)
      end
      @device_name = fields.to_h['value']
    end

    def update_attribute(attribute, value)
      unless instance_variable_get(:"@#{attribute}") == value
        instance_variable_set(:"@#{attribute}", value)
        @cb&.[](self, attribute, value)
      end
    end
  end
end
