require "./userspace/*"
require "./driver_thread.cr"

private lib Kernel
  fun ksyscall_switch(frame : Idt::Data::Registers*) : NoReturn
end

module Multiprocessing
  extend self

  # must be page aligned
  USER_STACK_SIZE         =   0x80_0000u64 # 8 mb
  USER_STACK_TOP          = 0xFFFF_F000u64
  USER_STACK_TOP64        = 0x7F_FFFF_F000u64
  USER_STACK_BOTTOM_MAX   = USER_STACK_TOP - USER_STACK_SIZE
  USER_STACK_BOTTOM_MAX64 = USER_STACK_TOP64 - USER_STACK_SIZE

  USER_STACK_INITIAL   = 0xFFFF_FFFFu64
  USER_STACK_INITIAL64 = 0x7F_FFFF_FFFFu64
  USER_MMAP_INITIAL    = USER_STACK_BOTTOM_MAX
  USER_MMAP_INITIAL64  = USER_STACK_BOTTOM_MAX64

  KERNEL_STACK_INITIAL = Paging::KERNEL_PDPT_POINTER + 0x7F_FFFF_FFFFu64
  KERNEL_HEAP_INITIAL  = Paging::KERNEL_PDPT_POINTER + 0x0u64

  USER_CS_SEGMENT   =  0x1b
  USER_DS_SEGMENT   =  0x23
  USER_CS64_SEGMENT =  0x2b
  USER_DS64_SEGMENT =  0x33
  USER_RFLAGS       = 0x212

  KERNEL_CS_SEGMENT =   0x39
  KERNEL_DS_SEGMENT =   0x41
  KERNEL_RFLAGS     = 0x1202 # IOPL=1

  FXSAVE_SIZE = 512u64

  @@first_process : Process? = nil
  @@last_process : Process? = nil
  class_property first_process, last_process

  @@pids = 1
  class_property pids

  @@n_process = 0
  class_property n_process

  @@fxsave_region = Pointer(UInt8).null
  @@fxsave_region_base = Pointer(UInt8).null
  class_property fxsave_region, fxsave_region_base

  @@procfs : ProcFS? = nil
  class_property procfs

  class Process
    @pid = 0
    getter pid

    @prev_process : Process? = nil
    @next_process : Process? = nil
    getter prev_process, next_process

    protected def prev_process=(@prev_process); end

    protected def next_process=(@next_process); end

    @initial_ip = 0x8000_0000u64
    property initial_ip

    @initial_sp = 0u64
    property initial_sp

    # physical location of the process' page directory
    @phys_pg_struct : UInt64 = 0u64
    property phys_pg_struct

    @phys_user_pg_struct : UInt64 = 0u64
    property phys_user_pg_struct

    # interrupt frame for preemptive multitasking
    @frame : Box(Idt::Data::Registers)? = nil
    property frame

    # sse state
    @fxsave_region = Pointer(UInt8).null
    getter fxsave_region

    @sched_data : Scheduler::ProcessData? = nil

    def sched_data
      @sched_data.not_nil!
    end

    # user-mode process data
    class UserData
      alias Waitable = Process | FileDescriptor | Array(FileDescriptor)

      # wait process / file
      # TODO: this should be a weak pointer once it's implemented
      @wait_object : Waitable? = nil
      property wait_object

      # wait timeout
      @wait_end = 0u64
      property wait_end

      # process group id
      @pgid = 0u64
      property pgid

      # files
      property fds

      # mmap
      getter mmap_list

      @mmap_heap : MemMapNode? = nil
      property mmap_heap

      # working directory
      property cwd, cwd_node

      # argv
      property argv

      # whether this process is a 64-bit or 32-bit process
      @is64 = false
      property is64

      class EnvVar
        getter key
        property value

        def initialize(@key : String, @value : String)
        end
      end

      # environment variables
      getter environ

      def initialize(@argv : Array(String),
                     @cwd : String, @cwd_node : VFSNode,
                     @environ = Array(EnvVar).new(0))
        @fds = Array(FileDescriptor?).new 4
        @mmap_list = MemMapList.new
      end

      # add a file descriptor and return it
      def install_fd(node : VFSNode, attrs) : Int32
        i = 0
        while i < @fds.size
          if @fds[i].nil?
            @fds[i] = FileDescriptor.new(i, node, attrs)
            return i
          end
          i += 1
        end
        @fds.push(FileDescriptor.new(i, node, attrs))
        @fds.size.to_i32 - 1
      end

      # gets a file descriptor or nil if it isn't opened
      def get_fd(i : Int32) : FileDescriptor?
        @fds[i]?
      end

      # closes a file descriptor
      def close_fd(i : Int32) : Bool
        return false unless i >= 0 && i <= @fds.size
        return false if @fds[i].nil?
        @fds[i].not_nil!.node.not_nil!.close
        @fds[i] = nil
        true
      end

      # gets an environment variable by key
      def getenv(key)
        @environ.each do |env|
          return env.not_nil!.value if env.not_nil!.key == key
        end
      end

      # set or override an environment variable
      def setenv(key, value, override = false)
        @environ.each do |env|
          if env.not_nil!.key == key
            return false unless override
            env.not_nil!.value = value
            return true
          end
        end
        @environ.push(EnvVar.new(key, value))
        true
      end

      # set wait timeout by microseconds
      def wait_usecs(usecs : UInt32)
        if usecs == (-1).to_u32
          @wait_end = 0
        else
          @wait_end = Time.usecs_since_boot + usecs
        end
      end

      def wait_usecs(usecs : UInt64)
        if usecs == (-1).to_u64
          @wait_end = 0
        else
          @wait_end = Time.usecs_since_boot + usecs
        end
      end
    end

    @udata : UserData? = nil
    getter! udata

    def kernel_process?
      @udata.nil?
    end

    getter name

    def initialize(@name : String?, @udata : UserData? = nil, &on_setup_paging : Process -> _)
      Multiprocessing.n_process += 1
      @pid = Multiprocessing.pids
      Multiprocessing.pids += 1

      if kernel_process?
        @initial_sp = KERNEL_STACK_INITIAL
      elsif @udata.not_nil!.is64
        @initial_sp = USER_STACK_INITIAL64
      else
        @initial_sp = USER_STACK_INITIAL
      end

      Idt.disable

      @fxsave_region = Pointer(UInt8).malloc_atomic(FXSAVE_SIZE)
      memcpy(@fxsave_region, Multiprocessing.fxsave_region_base, FXSAVE_SIZE)

      # create vmm map and save old vmm map
      last_pg_struct = Pointer(Paging::Data::PDPTable).null
      page_struct = Paging.alloc_process_pdpt
      if kernel_process?
        last_pg_struct = Paging.current_kernel_pdpt
        Paging.current_kernel_pdpt = Pointer(Paging::Data::PDPTable).new page_struct
      else
        last_pg_struct = Paging.current_pdpt
        Paging.current_pdpt = Pointer(Paging::Data::PDPTable).new page_struct
      end
      Paging.flush
      @phys_pg_struct = page_struct

      # setup process
      unless yield self
        # unable to setup, bailing
        if kernel_process?
          panic "unable to set up kernel process"
        end
        unless last_pg_struct.null?
          Paging.current_pdpt = last_pg_struct
          Paging.flush
        end
        Idt.enable
        Multiprocessing.n_process -= 1
        Multiprocessing.pids -= 1
        return
      end

      # append to linked list
      if Multiprocessing.first_process.nil?
        Multiprocessing.first_process = self
        Multiprocessing.last_process = self
      else
        Multiprocessing.last_process.not_nil!.next_process = self
        @prev_process = Multiprocessing.last_process
        Multiprocessing.last_process = self
      end

      # restore vmm map
      unless last_pg_struct.null?
        if kernel_process?
          Paging.current_kernel_pdpt = last_pg_struct
        else
          Paging.current_pdpt = last_pg_struct
        end
        Paging.flush
      end

      # append to procfs
      if Multiprocessing.procfs
        Multiprocessing.procfs.not_nil!.root.not_nil!.create_for_process(self)
      end

      # append to scheduler
      @sched_data = Scheduler.append_process self

      Idt.enable
    end

    def initial_switch
      Multiprocessing::Scheduler.current_process = self
      panic "page dir is nil" if @phys_pg_struct == 0
      if kernel_process?
        DriverThread.lock
        Paging.current_kernel_pdpt = Pointer(Paging::Data::PDPTable).new(@phys_pg_struct)
        Paging.flush
      else
        Paging.current_pdpt = Pointer(Paging::Data::PDPTable).new(@phys_pg_struct)
        Paging.flush
      end
      Kernel.ksyscall_switch(@frame.not_nil!.to_unsafe)
    end

    # new register frame for multitasking
    def new_frame
      frame = Idt::Data::Registers.new
      frame.userrsp = @initial_sp
      frame.rip = @initial_ip
      if kernel_process?
        frame.rflags = KERNEL_RFLAGS
        frame.cs = KERNEL_CS_SEGMENT
        frame.ss = KERNEL_DS_SEGMENT
        frame.ds = KERNEL_DS_SEGMENT
      else
        frame.rflags = USER_RFLAGS
        if udata.is64
          frame.cs = USER_CS64_SEGMENT
          frame.ss = USER_DS64_SEGMENT
          frame.ds = USER_DS64_SEGMENT
        else
          frame.cs = USER_CS_SEGMENT
          frame.ss = USER_DS_SEGMENT
          frame.ds = USER_DS_SEGMENT
        end
      end

      if @frame.nil?
        @frame = Box.new(frame)
      else
        @frame.not_nil!.to_unsafe.value = frame
      end
    end

    def new_frame_from_syscall(syscall_frame : Syscall::Data::Registers*)
      frame = Idt::Data::Registers.new

      {% for id in [
                     "rbp", "rdi", "rsi",
                     "r15", "r14", "r13", "r12", "r11", "r10", "r9", "r8",
                     "rdx", "rcx", "rbx", "rax",
                   ] %}
      frame.{{ id.id }} = syscall_frame.value.{{ id.id }}
      {% end %}

      # setup frame for waking up
      if kernel_process?
        frame.rip = syscall_frame.value.rcx
        frame.userrsp = syscall_frame.value.rsp

        frame.rflags = frame.r11
        frame.cs = KERNEL_CS_SEGMENT
        frame.ss = KERNEL_DS_SEGMENT
        frame.ds = KERNEL_DS_SEGMENT
      else
        frame.rflags = USER_RFLAGS
        if udata.is64
          frame.cs = USER_CS64_SEGMENT
          frame.ss = USER_DS64_SEGMENT
          frame.ds = USER_DS64_SEGMENT

          frame.rip = syscall_frame.value.rcx
          frame.userrsp = syscall_frame.value.rsp
        else
          frame.cs = USER_CS_SEGMENT
          frame.ss = USER_DS_SEGMENT
          frame.ds = USER_DS_SEGMENT

          frame.rip = Pointer(UInt32).new(syscall_frame.value.rcx).value
          frame.userrsp = syscall_frame.value.rcx & 0xFFFF_FFFFu64
        end
      end

      if @frame.nil?
        @frame = Box.new(frame)
      else
        @frame.not_nil!.to_unsafe.value = frame
      end
    end

    # spawn user process and move the lower-half of the current the address space
    # to the newly-spawned user process
    @[NoInline]
    def self.spawn_user(udata : UserData, result : ElfReader::Result)
      udata.is64 = result.is64
      old_pdpt = Pointer(Paging::Data::PDPTable)
        .new(Paging.mt_addr(Paging.current_pdpt.address))
      Multiprocessing::Process.new(udata.argv[0].not_nil!, udata) do |process|
        process.initial_ip = result.initial_ip

        new_pdpt = Pointer(Paging::Data::PDPTable)
          .new(Paging.mt_addr(process.phys_pg_struct))

        512.times do |dir_idx|
          # move the pdpt over and zero out the source
          new_pdpt.value.dirs[dir_idx] = old_pdpt.value.dirs[dir_idx]
          old_pdpt.value.dirs[dir_idx] = 0u64
        end
        Paging.current_pdpt = Pointer(Void).new(process.phys_pg_struct)
        Paging.flush

        # memory map
        result.mmap_list.each do |mmap_node|
          next if mmap_node.memsz == 0u64
          region_start = Paging.t_addr(mmap_node.vaddr)
          region_end = Paging.aligned(mmap_node.vaddr + mmap_node.memsz)
          region_size = region_end - region_start
          udata.mmap_list.add(region_start, region_size, mmap_node.attrs)
        end

        # heap
        udata.mmap_heap = udata.mmap_list.add(result.heap_start, 0,
          MemMapNode::Attributes::Read | MemMapNode::Attributes::Write).not_nil!

        # stack
        stack_size = 0x1000u64 * 4
        stack_addr = process.initial_sp - stack_size
        stack = Paging.alloc_page_pg(stack_addr, true, true, 4)
        zero_page Pointer(UInt8).new(stack), 4
        udata.mmap_list.add(stack_addr, stack_size,
          MemMapNode::Attributes::Read | MemMapNode::Attributes::Write | MemMapNode::Attributes::Stack)

        # argv
        argv_builder = ArgvBuilder.new process
        udata.argv.each do |arg|
          argv_builder.from_string arg.not_nil!
        end
        if udata.is64
          argv_builder.build64
        else
          argv_builder.build32
        end
        true
      end
    end

    @[NoInline]
    def self.spawn_user_drv(udata : UserData, result : ElfReader::Result)
      retval = 0u64
      asm("syscall"
              : "={rax}"(retval)
              : "{rax}"(SC_PROCESS_CREATE_DRV),
                "{rbx}"(pointerof(result)),
                "{rdx}"(udata)
              : "cc", "volatile", "memory", "{rcx}", "{r11}", "{rdi}", "{rsi}")
      retval
    end

    # spawn kernel process with optional argument
    def self.spawn_kernel(name : String, function, arg : Void*? = nil, stack_pages = 1, &block)
      Multiprocessing::Process.new(name) do |process|
        stack_start = Paging.t_addr(process.initial_sp) - (stack_pages - 1) * 0x1000
        stack = Paging.alloc_page_pg(stack_start, true, false, npages: stack_pages.to_u64)
        process.initial_ip = function.pointer.address

        yield process

        unless arg.nil?
          process.new_frame
          process.frame.not_nil!.to_unsafe.value.rdi = arg.not_nil!.address
        end
        true
      end
    end

    # deinitialize
    def remove(remove_proc? = true)
      Multiprocessing.n_process -= 1
      @prev_process.not_nil!.next_process = @next_process
      if @next_process.nil?
        Multiprocessing.last_process = @prev_process
      else
        @next_process.not_nil!.prev_process = @prev_process
      end
      if @udata
        # cleanup file descriptors
        udata.fds.each do |fd|
          unless fd.nil?
            fd.not_nil!.node.not_nil!.close
          end
        end
        # cleanup memory mapped regions
        udata.mmap_list.each do |node|
          if node.attr.includes?(MemMapNode::Attributes::SharedMem)
            node.shm_node.not_nil!.munmap(node, self)
          end
        end
      end
      # cleanup gc data so as to minimize leaks
      @fxsave_region = Pointer(UInt8).null
      @udata = nil
      @frame = nil
      @prev_process = nil
      @next_process = nil
      # remove from scheduler
      Scheduler.remove_process self
      @sched_data = nil
      # remove from procfs
      if !Multiprocessing.procfs.nil? && remove_proc?
        Multiprocessing.procfs.not_nil!.root.not_nil!.remove_for_process(self)
      end
    end

    def removed?
      @sched_data.nil?
    end

    # write address to page without switching tlb to the process' pdpt
    def write_to_virtual(virt_ptr : UInt8*, byte : UInt8)
      return false if @phys_pg_struct == 0

      virt_addr = virt_ptr.address
      return false if virt_addr > Paging::PDPT_SIZE

      offset = virt_addr & 0xFFF
      _, dir_idx, table_idx, page_idx = Paging.page_layer_indexes(virt_addr)

      pdpt = Pointer(Paging::Data::PDPTable)
        .new(Paging.mt_addr @phys_pg_struct)

      pd = Pointer(Paging::Data::PageDirectory).new(Paging.mt_addr pdpt.value.dirs[dir_idx])
      return false if pd.null?

      pt = Pointer(Paging::Data::PageTable).new(Paging.mt_addr pd.value.tables[table_idx])
      return false if pt.null?

      bytes = Pointer(UInt8).new(Paging.mt_addr(pt.value.pages[page_idx]))
      bytes[offset] = byte

      true
    end

    # get physical page where the address belongs to
    def physical_page_for_address(virt_addr : UInt64)
      return if @phys_pg_struct == 0
      return if virt_addr > Paging::PDPT_SIZE

      _, dir_idx, table_idx, page_idx = Paging.page_layer_indexes(virt_addr)

      pdpt = Pointer(Paging::Data::PDPTable)
        .new(Paging.mt_addr @phys_pg_struct)

      pd = Pointer(Paging::Data::PageDirectory).new(Paging.mt_addr pdpt.value.dirs[dir_idx])
      return if pd.null?

      pt = Pointer(Paging::Data::PageTable).new(Paging.mt_addr pd.value.tables[table_idx])
      return if pt.null?

      Pointer(UInt8).new(Paging.mt_addr(pt.value.pages[page_idx]))
    end

    # debugging
    def to_s(io)
      io.print "Process {\n"
      io.print " pid: ", @pid, ", \n"
      io.print " name: ", @name, ", \n"
      io.print " status: ", @sched_data.not_nil!.status, ", \n"
      io.print " initial_sp: ", Pointer(Void).new(@initial_sp), ", \n"
      io.print " initial_ip: ", Pointer(Void).new(@initial_ip), ", \n"
      if @frame
        io.print " ip: ", Pointer(Void).new(@frame.not_nil!.to_unsafe.value.rip), ", \n"
      end
      io.print "}"
    end

    protected def unawait
      @sched_data.not_nil!.status =
        Multiprocessing::Scheduler::ProcessData::Status::Normal
      @udata.not_nil!.wait_object = nil
      @udata.not_nil!.wait_end = 0u64
    end
  end

  # sleep from kernel thread
  def sleep_drv
    retval = 0u64
    asm("syscall"
            : "={rax}"(retval)
            : "{rax}"(SC_SLEEP)
            : "cc", "memory", "{rcx}", "{r11}", "{rdi}", "{rsi}")
    retval
  end

  # iteration
  def each
    process = @@first_process
    while !process.nil?
      process = process.not_nil!
      yield process
      process = process.next_process
    end
  end
end
