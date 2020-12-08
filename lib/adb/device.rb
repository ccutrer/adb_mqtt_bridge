require 'io/wait'
require 'shellwords'

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
      :foreground_app_package,
      :foreground_app,
      :current_window,
      :playback_state,
      :playback_position,
      :playback_duration,
      :playback_speed,
      :playback_actions,
      :playback_title,
      :playback_artist,
      :playback_album,
      :playback_track,
      :playback_track_count

    EVENT_REGEX = /^(\S+):\s+(\S+)\s+(\S+)\s+(\S+)\s*$/
    private_constant :EVENT_REGEX

    def close
      @adb.close
    end

    def getevents
      getevent = IO.popen("adb -s #{adb_serial} shell -t -t getevent -ql", "w+")
      loop do
        line = getevent.gets
        next unless line =~ EVENT_REGEX
        yield($3, $4) if $2 == 'EV_KEY'
      end
    ensure
      getevent.close
    end

    def update
      system("dumpsys window windows | grep mCurrentFocus=") =~
        /^  mCurrentFocus=Window{[0-9a-f]+ u0 ([a-zA-Z0-9.]+)\/([a-zA-Z0-9.]+)}\n$/
      update_attribute(:foreground_app_package, $1)
      update_attribute(:current_window, $2)

      if foreground_app_package
        escaped_package = Shellwords.escape(Regexp.escape(foreground_app_package))
        info = system("dumpsys bluetooth_manager | grep -A3 #{escaped_package}")
        playback_state = system("dumpsys media_session | grep -A9 #{escaped_package}").
          match(/PlaybackState {(.+)}/)&.[](1)

        update_attribute(:foreground_app, info.match(/MediaPlayerInfo #{Regexp.escape(foreground_app_package)} \(as '(.+)'\) Type = /)&.[](1) || '')
      else
        update_attribute(:foreground_app, '')
      end

      song = info&.match(/Song: {(.+)}/)&.[](1)
      if song
        song = parse_song(song)
        update_attribute(:playback_duration, song['duration'].to_i / 1000.0)
        %w{title artist album}.each do |attr|
          value = song[attr]
          value = '' if value == 'Not Provided'
          update_attribute(:"playback_#{attr}", value)
        end
        track, track_count = song['trackPosition'].split('/', 2).map(&:to_i)
        update_attribute(:playback_track, track)
        update_attribute(:playback_track_count, track_count)
      else
        update_attribute(:playback_duration, '')
        update_attribute(:playback_title, '')
        update_attribute(:playback_artist, '')
        update_attribute(:playback_album, '')
        update_attribute(:playback_track, '')
        update_attribute(:playback_track_count, '')
      end

      if playback_state
        playback_state = playback_state.split(", ").map { |kv| kv.split("=", 2) }.to_h
        state = PLAYBACK_STATES[playback_state['state'].to_i]
        position = playback_state['position'].to_f / 1000
        if state == :playing
          now = system("cat /proc/uptime").to_f
          position += now - playback_state['updated'].to_i / 1000.0
        end

        if playback_duration > 0 && position > playback_duration
          # wtf? it's _not_ still playing
          update_attribute(:playback_state, :stopped)
          update_attribute(:playback_position, playback_duration)
        else
          update_attribute(:playback_state, state)
          update_attribute(:playback_position, position)
        end
        update_attribute(:playback_speed, playback_state['speed'].to_f)
        actions = []
        action_flags = playback_state['actions'].to_i
        PLAYBACK_ACTIONS.each do |(flag, sym)|
          actions << sym if (action_flags & flag) == flag
        end
        update_attribute(:playback_actions, actions)
      else
        update_attribute(:playback_state, '')
        update_attribute(:playback_position, '')
        update_attribute(:playback_speed, '')
        update_attribute(:playback_actions, [])
      end


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

    def parse_song(object)
      result = {}
      object.scan(/([A-Za-z]+)=("[^"]+"|[^ ]+)/) do |kv|
        v = kv.last
        v = v[1..-2] if v[0] == '"'
        result[kv.first] = v
      end
      result
    end
  end
end
