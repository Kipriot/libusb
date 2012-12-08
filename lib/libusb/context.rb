# This file is part of Libusb for Ruby.
#
# Libusb for Ruby is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Libusb for Ruby is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with Libusb for Ruby.  If not, see <http://www.gnu.org/licenses/>.

require 'libusb/call'

module LIBUSB
  # Class representing a libusb session.
  class Context
    class Pollfd
      include Comparable

      def initialize(fd, events=0)
        @fd, @events = fd, events
      end

      def <=>(other)
        @fd <=> other.fd
      end

      # @return [IO]  IO object bound to the file descriptor.
      def io
        IO.new @fd
      end

      # @return [Integer]  Numeric file descriptor
      attr_reader :fd

      # @return [Integer]  Event flags to poll for
      attr_reader :events

      def pollin?
        @events & POLLIN != 0
      end

      def pollout?
        @events & POLLOUT != 0
      end

      def inspect
        "\#<#{self.class} fd:#{@fd}#{' POLLIN' if pollin?}#{' POLLOUT' if pollout?}>"
      end
    end


    # Initialize libusb context.
    def initialize
      m = FFI::MemoryPointer.new :pointer
      Call.libusb_init(m)
      @ctx = m.read_pointer
      @on_pollfd_added = nil
      @on_pollfd_removed = nil
    end

    # Deinitialize libusb.
    #
    # Should be called after closing all open devices and before your application terminates.
    def exit
      Call.libusb_exit(@ctx)
    end

    # Set message verbosity.
    #
    # * Level 0: no messages ever printed by the library (default)
    # * Level 1: error messages are printed to stderr
    # * Level 2: warning and error messages are printed to stderr
    # * Level 3: informational messages are printed to stdout, warning and
    #   error messages are printed to stderr
    #
    # The default level is 0, which means no messages are ever printed. If you
    # choose to increase the message verbosity level, ensure that your
    # application does not close the stdout/stderr file descriptors.
    #
    # You are advised to set level 3. libusb is conservative with its message
    # logging and most of the time, will only log messages that explain error
    # conditions and other oddities. This will help you debug your software.
    #
    # If the LIBUSB_DEBUG environment variable was set when libusb was
    # initialized, this method does nothing: the message verbosity is
    # fixed to the value in the environment variable.
    #
    # If libusb was compiled without any message logging, this method
    # does nothing: you'll never get any messages.
    #
    # If libusb was compiled with verbose debug message logging, this
    # method does nothing: you'll always get messages from all levels.
    #
    # @param [Fixnum] level  debug level to set
    def debug=(level)
      Call.libusb_set_debug(@ctx, level)
    end

    def device_list
      pppDevs = FFI::MemoryPointer.new :pointer
      size = Call.libusb_get_device_list(@ctx, pppDevs)
      ppDevs = pppDevs.read_pointer
      pDevs = []
      size.times do |devi|
        pDev = ppDevs.get_pointer(devi*FFI.type_size(:pointer))
        pDevs << Device.new(self, pDev)
      end
      Call.libusb_free_device_list(ppDevs, 1)
      pDevs
    end
    private :device_list

    # Handle any pending events in blocking mode.
    #
    # This method must be called when libusb is running asynchronous transfers.
    # This gives libusb the opportunity to reap pending transfers,
    # invoke callbacks, etc.
    #
    # If a zero timeout is passed, this function will handle any already-pending
    # events and then immediately return in non-blocking style.
    #
    # If a non-zero timeout is passed and no events are currently pending, this
    # method will block waiting for events to handle up until the specified timeout.
    # If an event arrives or a signal is raised, this method will return early.
    #
    # If the parameter completion_flag is used, then after obtaining the event
    # handling lock this function will return immediately if the flag is set to completed.
    # This allows for race free waiting for the completion of a specific transfer.
    #
    # @param [Integer, nil] timeout  the maximum time (in millseconds) to block waiting for
    #                                events, or 0 for non-blocking mode
    # @param [Call::CompletionFlag, nil] completion_flag  CompletionFlag to check
    def handle_events(timeout=nil, completion_flag=nil)
      if completion_flag && !completion_flag.is_a?(Call::CompletionFlag)
        raise ArgumentError, "completion_flag is not a CompletionFlag"
      end
      if timeout
        timeval = Call::Timeval.new
        timeval.in_ms = timeout
        res = if Call.respond_to?(:libusb_handle_events_timeout_completed)
          Call.libusb_handle_events_timeout_completed(@ctx, timeval, completion_flag)
        else
          Call.libusb_handle_events_timeout(@ctx, timeval)
        end
      else
        res = if Call.respond_to?(:libusb_handle_events_completed)
          Call.libusb_handle_events_completed(@ctx, completion_flag )
        else
          Call.libusb_handle_events(@ctx)
        end
      end
      LIBUSB.raise_error res, "in libusb_handle_events" if res<0
    end

    # Obtain a list of devices currently attached to the USB system, optionally matching certain criteria.
    #
    # @param [Hash] filter_hash  A number of criteria can be defined in key-value pairs.
    #   Only devices that equal all given criterions will be returned. If a criterion is
    #   not specified or its value is +nil+, any device will match that criterion.
    #   The following criteria can be filtered:
    #   * <tt>:idVendor</tt>, <tt>:idProduct</tt> (+FixNum+) for matching vendor/product ID,
    #   * <tt>:bClass</tt>, <tt>:bSubClass</tt>, <tt>:bProtocol</tt> (+FixNum+) for the device type -
    #     Devices using CLASS_PER_INTERFACE will match, if any of the interfaces match.
    #   * <tt>:bcdUSB</tt>, <tt>:bcdDevice</tt>, <tt>:bMaxPacketSize0</tt> (+FixNum+) for the
    #     USB and device release numbers.
    #   Criteria can also specified as Array of several alternative values.
    #
    # @example
    #   # Return all devices of vendor 0x0ab1 where idProduct is 3 or 4:
    #   context.device :idVendor=>0x0ab1, :idProduct=>[0x0003, 0x0004]
    #
    # @return [Array<LIBUSB::Device>]
    def devices(filter_hash={})
      device_list.select do |dev|
        ( !filter_hash[:bClass] || (dev.bDeviceClass==CLASS_PER_INTERFACE ?
                             dev.settings.map(&:bInterfaceClass).&([filter_hash[:bClass]].flatten).any? :
                             [filter_hash[:bClass]].flatten.include?(dev.bDeviceClass))) &&
        ( !filter_hash[:bSubClass] || (dev.bDeviceClass==CLASS_PER_INTERFACE ?
                             dev.settings.map(&:bInterfaceSubClass).&([filter_hash[:bSubClass]].flatten).any? :
                             [filter_hash[:bSubClass]].flatten.include?(dev.bDeviceSubClass))) &&
        ( !filter_hash[:bProtocol] || (dev.bDeviceClass==CLASS_PER_INTERFACE ?
                             dev.settings.map(&:bInterfaceProtocol).&([filter_hash[:bProtocol]].flatten).any? :
                             [filter_hash[:bProtocol]].flatten.include?(dev.bDeviceProtocol))) &&
        ( !filter_hash[:bMaxPacketSize0] || [filter_hash[:bMaxPacketSize0]].flatten.include?(dev.bMaxPacketSize0) ) &&
        ( !filter_hash[:idVendor] || [filter_hash[:idVendor]].flatten.include?(dev.idVendor) ) &&
        ( !filter_hash[:idProduct] || [filter_hash[:idProduct]].flatten.include?(dev.idProduct) ) &&
        ( !filter_hash[:bcdUSB] || [filter_hash[:bcdUSB]].flatten.include?(dev.bcdUSB) ) &&
        ( !filter_hash[:bcdDevice] || [filter_hash[:bcdDevice]].flatten.include?(dev.bcdDevice) )
      end
    end


    # Retrieve a list of file descriptors that should be polled by your main
    # loop as libusb event sources.
    #
    # As file descriptors are a Unix-specific concept, this function is not
    # available on Windows and will always return +nil+.
    #
    # @return [Array<Pollfd>]  list of Pollfd objects,
    #   +nil+ on error,
    #   +nil+ on platforms where the functionality is not available
    def pollfds
      ppPollfds = Call.libusb_get_pollfds(@ctx)
      return nil if ppPollfds.null?
      offs = 0
      pollfds = []
      while !(pPollfd=ppPollfds.get_pointer(offs)).null?
        pollfd = Call::Pollfd.new pPollfd
        pollfds << Pollfd.new(pollfd[:fd], pollfd[:events])
        offs += FFI.type_size :pointer
      end
      # ppPollfds has to be released by free() -> give the GC this job
      ppPollfds.autorelease = true
      pollfds
    end

    # Determine the next internal timeout that libusb needs to handle.
    #
    # You only need to use this function if you are calling poll() or select() or
    # similar on libusb's file descriptors yourself - you do not need to use it if
    # you are calling {#handle_events} directly.
    #
    # You should call this function in your main loop in order to determine how long
    # to wait for select() or poll() to return results. libusb needs to be called
    # into at this timeout, so you should use it as an upper bound on your select() or
    # poll() call.
    #
    # When the timeout has expired, call into {#handle_events} (perhaps
    # in non-blocking mode) so that libusb can handle the timeout.
    #
    # This function may return zero. If this is the
    # case, it indicates that libusb has a timeout that has already expired so you
    # should call {#handle_events} immediately. A return code
    # of +nil+ indicates that there are no pending timeouts.
    #
    # On some platforms, this function will always returns +nil+ (no pending timeouts).
    # See libusb's notes on time-based events.
    #
    # @return [Float, nil]  the timeout in seconds
    def next_timeout
      timeval = Call::Timeval.new
      res = Call.libusb_get_next_timeout @ctx, timeval
      LIBUSB.raise_error res, "in libusb_get_next_timeout" if res<0
      res == 1 ? timeval.in_s : nil
    end

    # Register a notification block for file descriptor additions.
    #
    # This block will be invoked for every new file descriptor that
    # libusb uses as an event source.
    #
    # Note that file descriptors may have been added even before you register these
    # notifiers (e.g. at {Context#initialize} time).
    def on_pollfd_added &block
      @on_pollfd_added = proc do |fd, events, _|
        pollfd = Pollfd.new fd, events
        block.call pollfd
      end
      Call.libusb_set_pollfd_notifiers @ctx, @on_pollfd_added, @on_pollfd_removed, nil
    end

    # Register a notification block for file descriptor removals.
    #
    # This block will be invoked for every removed file descriptor that
    # libusb uses as an event source.
    #
    # Note that the removal notifier may be called during {Context#exit}
    # (e.g. when it is closing file descriptors that were opened and added to the poll
    # set at {Context#initialize} time). If you don't want this, overwrite the notifier
    # immediately before calling {Context#exit}.
    def on_pollfd_removed &block
      @on_pollfd_removed = proc do |fd, _|
        pollfd = Pollfd.new fd
        block.call pollfd
      end
      Call.libusb_set_pollfd_notifiers @ctx, @on_pollfd_added, @on_pollfd_removed, nil
    end
  end
end
