//=============================================================================
// Package     : apb_slave_uvm_pkg
// Category    : bus
// Description : UVM environment for apb_slave (UVM 1800.2-2020).
//
//   apb_agent        the APB4 requester: a driver that runs setup and access
//                    phases with random idle gaps, a monitor that publishes
//                    every completed transfer with its wait states
//   reg_responder    the register block behind the bridge, reactive: random
//                    reg_ready wait states, read data from its own memory,
//                    an error for addresses at or above ERR_BASE
//   reg_monitor      publishes every accepted register request
//   apb_scoreboard   pairs each APB transfer with exactly one register
//                    request and checks the payload, PRDATA and PSLVERR; an
//                    independent reference memory predicts every read; a
//                    covergroup records kinds, errors and wait states
//
// Tests: apb_random_test (constrained-random traffic against a slow register
// block) and apb_back_to_back_test (no gaps, no wait states, and the exact
// cycle count of a transfer). A test prints "** UVM TEST PASSED **" only when
// the scoreboard checked every transfer, every coverage bin was hit and no
// UVM error was reported.
//
// Drivers assign one time unit after the rising edge, monitors sample on the
// falling edge; there are no clocking blocks (see apb_slave_if).
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
package apb_slave_uvm_pkg;

  import uvm_pkg::*;

  localparam int unsigned AW = 12;
  localparam int unsigned DW = 32;
  localparam int unsigned SW = DW / 8;
  localparam logic [AW-1:0] ERR_BASE = 12'h800;

  typedef virtual apb_slave_if #(.AW(AW), .DW(DW)) apb_vif_t;

  //---------------------------------------------------------------------------
  // Transactions
  //---------------------------------------------------------------------------
  class apb_item extends uvm_sequence_item;
    rand bit          write;
    rand bit [AW-1:0] addr;
    rand bit [DW-1:0] wdata;
    rand bit [SW-1:0] strb;
    rand bit [2:0]    prot;
    rand int unsigned idle;          // idle cycles before the setup phase

    // Filled in by the monitor
    bit [DW-1:0] rdata;
    bit          slverr;
    int unsigned waits;              // access cycles with PREADY low

    int unsigned max_idle = 3;
    int unsigned err_pct  = 10;

    constraint c_read_strb { !write -> strb == '0; }
    constraint c_idle      { idle <= max_idle;
                             idle dist { 0 := 6, [1:3] := 3, [4:16] := 1 }; }
    // Most traffic hits a small window, so reads often return written data.
    constraint c_addr      { addr dist { [12'h000:12'h03F] := (100 - err_pct),
                                         [ERR_BASE:12'hFFF] := err_pct }; }

    `uvm_object_utils(apb_item)

    function new(string name = "apb_item");
      super.new(name);
    endfunction

    virtual function string convert2string();
      return $sformatf("%s addr=%03h wdata=%08h strb=%b prot=%0d rdata=%08h slverr=%0b waits=%0d",
                       write ? "WR" : "RD", addr, wdata, strb, prot, rdata, slverr, waits);
    endfunction
  endclass

  class reg_item extends uvm_sequence_item;
    bit          write;
    bit [AW-1:0] addr;
    bit [DW-1:0] wdata;
    bit [SW-1:0] strb;
    bit [2:0]    prot;
    bit [DW-1:0] rdata;
    bit          error;

    `uvm_object_utils(reg_item)

    function new(string name = "reg_item");
      super.new(name);
    endfunction
  endclass

  //---------------------------------------------------------------------------
  // APB agent
  //---------------------------------------------------------------------------
  typedef uvm_sequencer #(apb_item) apb_sequencer;

  class apb_driver extends uvm_driver #(apb_item);
    `uvm_component_utils(apb_driver)
    apb_vif_t vif;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(apb_vif_t)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "apb_driver: no virtual interface")
    endfunction

    task run_phase(uvm_phase phase);
      vif.psel    <= 1'b0;
      vif.penable <= 1'b0;
      vif.pwrite  <= 1'b0;
      vif.paddr   <= '0;
      vif.pwdata  <= '0;
      vif.pstrb   <= '0;
      vif.pprot   <= '0;
      wait (vif.rst_n === 1'b1);
      @(posedge vif.clk); #1;
      // Every item starts one time unit after a rising edge.
      forever begin
        seq_item_port.get_next_item(req);
        repeat (req.idle) begin
          vif.psel    = 1'b0;
          vif.penable = 1'b0;
          @(posedge vif.clk); #1;
        end
        // Setup phase
        vif.psel    = 1'b1;
        vif.penable = 1'b0;
        vif.pwrite  = req.write;
        vif.paddr   = req.addr;
        vif.pwdata  = req.wdata;
        vif.pstrb   = req.strb;
        vif.pprot   = req.prot;
        @(posedge vif.clk); #1;
        // Access phase, held until PREADY
        vif.penable = 1'b1;
        forever begin
          @(negedge vif.clk);
          if (vif.pready) break;
          @(posedge vif.clk); #1;
        end
        @(posedge vif.clk); #1;
        vif.psel    = 1'b0;
        vif.penable = 1'b0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class apb_monitor extends uvm_monitor;
    `uvm_component_utils(apb_monitor)
    apb_vif_t vif;
    uvm_analysis_port #(apb_item) ap;
    int unsigned registered = 1;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(apb_vif_t)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "apb_monitor: no virtual interface")
      void'(uvm_config_db#(int unsigned)::get(this, "", "registered", registered));
    endfunction

    task run_phase(uvm_phase phase);
      int unsigned waits = 0;
      forever begin
        @(negedge vif.clk);
        if (vif.rst_n !== 1'b1) begin
          waits = 0;
          continue;
        end
        // APB4 only recommends PSLVERR low outside the cycle it is sampled
        // in; the direct path passes reg_error through, REGISTERED promises it.
        if (registered && vif.pslverr && !(vif.psel && vif.penable && vif.pready))
          `uvm_error("APB", "PSLVERR high outside a completing access phase")
        if (vif.psel && vif.penable) begin
          if (vif.pready) begin
            apb_item t = apb_item::type_id::create("t");
            t.write  = vif.pwrite;
            t.addr   = vif.paddr;
            t.wdata  = vif.pwdata;
            t.strb   = vif.pstrb;
            t.prot   = vif.pprot;
            t.rdata  = vif.prdata;
            t.slverr = vif.pslverr;
            t.waits  = waits;
            ap.write(t);
            waits = 0;
          end else begin
            waits++;
          end
        end
      end
    endtask
  endclass

  class apb_agent extends uvm_agent;
    `uvm_component_utils(apb_agent)
    apb_sequencer sqr;
    apb_driver    drv;
    apb_monitor   mon;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sqr = apb_sequencer::type_id::create("sqr", this);
      drv = apb_driver::type_id::create("drv", this);
      mon = apb_monitor::type_id::create("mon", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  //---------------------------------------------------------------------------
  // Register side
  //---------------------------------------------------------------------------
  class reg_responder extends uvm_component;
    `uvm_component_utils(reg_responder)
    apb_vif_t vif;
    int unsigned ready_pct = 60;
    bit [DW-1:0] mem [bit [AW-1:0]];

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(apb_vif_t)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "reg_responder: no virtual interface")
      void'(uvm_config_db#(int unsigned)::get(this, "", "ready_pct", ready_pct));
    endfunction

    function bit [DW-1:0] read_word(bit [AW-1:0] a);
      return mem.exists(a) ? mem[a] : '0;
    endfunction

    task run_phase(uvm_phase phase);
      vif.reg_ready <= 1'b0;
      vif.reg_rdata <= '0;
      vif.reg_error <= 1'b0;
      fork
        // reg_ready: random wait states, chosen after each edge
        forever begin
          @(posedge vif.clk); #1;
          vif.reg_ready = ($urandom_range(0, 99) < ready_pct);
        end
        // The response follows the request combinationally, as a register
        // block's read mux would; it is updated once the request has settled.
        // The read mux does not care about reg_write, so a write sees the
        // addressed word on reg_rdata too: zeroing it is the bridge's job.
        forever begin
          @(posedge vif.clk); #2;
          vif.reg_error = (vif.reg_addr >= ERR_BASE);
          vif.reg_rdata = read_word(vif.reg_addr);
        end
        // The write takes effect on the accepting edge.
        forever begin
          @(negedge vif.clk);
          if (vif.rst_n === 1'b1 && vif.reg_valid && vif.reg_ready && vif.reg_write
              && vif.reg_addr < ERR_BASE) begin
            bit [DW-1:0] w = read_word(vif.reg_addr);
            for (int b = 0; b < SW; b++)
              if (vif.reg_strb[b]) w[8*b +: 8] = vif.reg_wdata[8*b +: 8];
            mem[vif.reg_addr] = w;
          end
        end
      join
    endtask
  endclass

  class reg_monitor extends uvm_monitor;
    `uvm_component_utils(reg_monitor)
    apb_vif_t vif;
    uvm_analysis_port #(reg_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(apb_vif_t)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "reg_monitor: no virtual interface")
    endfunction

    task run_phase(uvm_phase phase);
      forever begin
        @(negedge vif.clk);
        if (vif.rst_n !== 1'b1) continue;
        if (vif.reg_valid && !(vif.psel && vif.penable))
          `uvm_error("REG", "reg_valid outside an APB access phase")
        if (vif.reg_valid && vif.reg_ready) begin
          reg_item t = reg_item::type_id::create("t");
          t.write = vif.reg_write;
          t.addr  = vif.reg_addr;
          t.wdata = vif.reg_wdata;
          t.strb  = vif.reg_strb;
          t.prot  = vif.reg_prot;
          t.rdata = vif.reg_rdata;
          t.error = vif.reg_error;
          ap.write(t);
        end
      end
    endtask
  endclass

  //---------------------------------------------------------------------------
  // Scoreboard and coverage
  //---------------------------------------------------------------------------
  class apb_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(apb_scoreboard)
    uvm_tlm_analysis_fifo #(apb_item) apb_fifo;
    uvm_tlm_analysis_fifo #(reg_item) reg_fifo;
    int unsigned registered = 1;
    int unsigned checks = 0;
    bit [DW-1:0] ref_mem [bit [AW-1:0]];   // independent of the responder's

    // Sampled values for the covergroup. cv_waits counts the wait states the
    // register block added: REGISTERED always inserts one of its own.
    bit          cv_write, cv_error;
    int unsigned cv_waits;
    bit [SW-1:0] cv_strb;

    covergroup cg;
      cp_write : coverpoint cv_write;
      cp_error : coverpoint cv_error;
      cp_waits : coverpoint cv_waits { bins none = {0}; bins one = {1}; bins two = {2};
                                       bins many = {[3:$]}; }
      cp_strb  : coverpoint cv_strb iff (cv_write) { bins none = {'0}; bins all = {'1};
                                                    bins some = default; }
      x_kind   : cross cp_write, cp_error;
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg = new();
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      apb_fifo = new("apb_fifo", this);
      reg_fifo = new("reg_fifo", this);
      void'(uvm_config_db#(int unsigned)::get(this, "", "registered", registered));
    endfunction

    task run_phase(uvm_phase phase);
      apb_item a;
      reg_item r;
      forever begin
        apb_fifo.get(a);
        if (!reg_fifo.try_get(r)) begin
          `uvm_error("SB", $sformatf("APB transfer with no register request: %s",
                                     a.convert2string()))
          continue;
        end
        check_pair(a, r);
      end
    endtask

    function void check_pair(apb_item a, reg_item r);
      bit [DW-1:0] want;
      checks++;
      if (r.write != a.write || r.addr != a.addr || r.wdata != a.wdata
          || r.strb != a.strb || r.prot != a.prot)
        `uvm_error("SB", $sformatf("request does not match the transfer: %s", a.convert2string()))
      if (a.slverr != r.error)
        `uvm_error("SB", $sformatf("PSLVERR %0b, register error %0b", a.slverr, r.error))
      if (a.slverr != (a.addr >= ERR_BASE))
        `uvm_error("SB", $sformatf("PSLVERR %0b at address %03h", a.slverr, a.addr))
      if (a.write) begin
        // REGISTERED returns zero on a write; the direct path passes reg_rdata.
        if (registered && a.rdata != '0)
          `uvm_error("SB", $sformatf("PRDATA %08h on a write", a.rdata))
        if (!a.slverr) begin
          bit [DW-1:0] w = ref_mem.exists(a.addr) ? ref_mem[a.addr] : '0;
          for (int b = 0; b < SW; b++)
            if (a.strb[b]) w[8*b +: 8] = a.wdata[8*b +: 8];
          ref_mem[a.addr] = w;
        end
      end else begin
        want = (a.slverr || !ref_mem.exists(a.addr)) ? '0 : ref_mem[a.addr];
        if (a.rdata != want)
          `uvm_error("SB", $sformatf("read %03h returned %08h, expected %08h", a.addr, a.rdata, want))
      end
      cv_write = a.write;
      cv_error = a.slverr;
      if (registered && a.waits == 0)
        `uvm_error("SB", "REGISTERED completed a transfer with no wait state")
      cv_waits = a.waits - ((registered && a.waits != 0) ? 1 : 0);
      cv_strb  = a.strb;
      cg.sample();
    endfunction

    function void check_phase(uvm_phase phase);
      if (!apb_fifo.is_empty() || !reg_fifo.is_empty())
        `uvm_error("SB", $sformatf("unmatched at the end: %0d transfers, %0d requests",
                                   apb_fifo.used(), reg_fifo.used()))
    endfunction
  endclass

  //---------------------------------------------------------------------------
  // Environment
  //---------------------------------------------------------------------------
  class apb_env extends uvm_env;
    `uvm_component_utils(apb_env)
    apb_agent      agent;
    reg_responder  responder;
    reg_monitor    rmon;
    apb_scoreboard sb;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent     = apb_agent::type_id::create("agent", this);
      responder = reg_responder::type_id::create("responder", this);
      rmon      = reg_monitor::type_id::create("rmon", this);
      sb        = apb_scoreboard::type_id::create("sb", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      agent.mon.ap.connect(sb.apb_fifo.analysis_export);
      rmon.ap.connect(sb.reg_fifo.analysis_export);
    endfunction
  endclass

  //---------------------------------------------------------------------------
  // Sequences
  //---------------------------------------------------------------------------
  class apb_rand_seq extends uvm_sequence #(apb_item);
    `uvm_object_utils(apb_rand_seq)
    int unsigned n        = 100;
    int unsigned max_idle = 3;
    int unsigned err_pct  = 10;

    function new(string name = "apb_rand_seq");
      super.new(name);
    endfunction

    task body();
      repeat (n) begin
        req = apb_item::type_id::create("req");
        req.max_idle = max_idle;
        req.err_pct  = err_pct;
        start_item(req);
        if (!req.randomize()) `uvm_fatal("RAND", "apb_item randomisation failed")
        finish_item(req);
      end
    endtask
  endclass

  //---------------------------------------------------------------------------
  // Tests
  //---------------------------------------------------------------------------
  class apb_base_test extends uvm_test;
    `uvm_component_utils(apb_base_test)
    apb_env      env;
    int unsigned n_items   = 600;
    int unsigned ready_pct = 60;
    int unsigned max_idle  = 3;
    int unsigned err_pct   = 10;
    bit          need_full_coverage = 1;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      uvm_config_db#(int unsigned)::set(this, "env.responder", "ready_pct", ready_pct);
      env = apb_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      apb_rand_seq seq = apb_rand_seq::type_id::create("seq");
      seq.n        = n_items;
      seq.max_idle = max_idle;
      seq.err_pct  = err_pct;
      phase.raise_objection(this);
      seq.start(env.agent.sqr);
      repeat (5) @(posedge env.agent.drv.vif.clk);
      phase.drop_objection(this);
    endtask

    virtual function bit extra_checks_ok();
      return 1'b1;
    endfunction

    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      real cov = env.sb.cg.get_coverage();
      `uvm_info("TEST", $sformatf("%0d transfers checked, coverage %0.1f%%",
                                  env.sb.checks, cov), UVM_LOW)
      if (env.sb.checks != n_items)
        `uvm_error("TEST", $sformatf("checked %0d transfers of %0d", env.sb.checks, n_items))
      if (need_full_coverage && cov < 100.0)
        `uvm_error("TEST", $sformatf("coverage %0.1f%% is below 100%%", cov))
      if (rs.get_severity_count(UVM_ERROR) == 0 && rs.get_severity_count(UVM_FATAL) == 0
          && extra_checks_ok())
        $display("** UVM TEST PASSED **");
    endfunction
  endclass

  class apb_random_test extends apb_base_test;
    `uvm_component_utils(apb_random_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
  endclass

  // No gaps and no wait states: every transfer takes exactly two cycles
  // (setup, access) on the direct path and three with REGISTERED.
  class apb_back_to_back_test extends apb_base_test;
    `uvm_component_utils(apb_back_to_back_test)
    longint unsigned first_setup, last_done;
    int unsigned     registered = 1;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      n_items   = 200;
      ready_pct = 100;
      max_idle  = 0;
      err_pct   = 0;
      need_full_coverage = 0;      // no errors and no wait states by design
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      void'(uvm_config_db#(int unsigned)::get(this, "", "registered", registered));
    endfunction

    task run_phase(uvm_phase phase);
      longint unsigned cycle = 0;
      bit seen = 0;
      fork
        forever begin
          @(negedge env.agent.drv.vif.clk);
          cycle++;
          if (!seen && env.agent.drv.vif.psel) begin
            first_setup = cycle;
            seen = 1;
          end
          if (env.agent.drv.vif.psel && env.agent.drv.vif.penable && env.agent.drv.vif.pready)
            last_done = cycle;
        end
      join_none
      super.run_phase(phase);
    endtask

    virtual function bit extra_checks_ok();
      longint unsigned want = n_items * (registered ? 3 : 2);
      longint unsigned took = last_done - first_setup + 1;
      if (took != want) begin
        `uvm_error("TEST", $sformatf("%0d transfers took %0d cycles, expected %0d",
                                     n_items, took, want))
        return 1'b0;
      end
      return 1'b1;
    endfunction
  endclass

endpackage
