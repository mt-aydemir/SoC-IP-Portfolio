//=============================================================================
// Package     : axi4_lite_slave_uvm_pkg
// Category    : bus
// Description : UVM environment for axi4_lite_slave (UVM 1800.2-2020).
//
//   axil_agent       the AXI4-Lite manager: a driver with independent write
//                    and read workers, so a write and a read can be in flight
//                    together; AW and W go out with random relative delays
//                    (either first, or the same cycle), BREADY and RREADY
//                    with random back-pressure. Its monitor pairs AW, W and B
//                    into writes and AR and R into reads, and checks the
//                    subordinate's hold rules on B and R
//   reg_responder    the register block, reactive: random reg_ready wait
//                    states, read data from its own memory, an error for
//                    addresses at or above ERR_BASE
//   reg_monitor      every accepted register request, with its wait states
//   axil_scoreboard  walks the register requests in the order the register
//                    block saw them - the order that decides what a read
//                    returns - pairs each with the next AXI transaction of
//                    its direction, checks address, protection, data,
//                    strobes and the response, and predicts every read from
//                    an independent reference memory; a covergroup records
//                    kinds, errors, AW/W order, back-pressure, wait states
//                    and read/write overlap
//
// Tests: axil_random_test (constrained-random mixed traffic against a slow
// register block) and axil_saturation_test (no gaps, no back-pressure, no
// wait states). A test prints "** UVM TEST PASSED **" only when every
// transaction was checked, coverage is complete where the test asks for it,
// and no UVM error was reported.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
package axi4_lite_slave_uvm_pkg;

  import uvm_pkg::*;

  localparam int unsigned AW = 12;
  localparam int unsigned DW = 32;
  localparam int unsigned SW = DW / 8;
  localparam logic [AW-1:0] ERR_BASE = 12'h800;
  localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10;

  typedef virtual axi4_lite_slave_if #(.AW(AW), .DW(DW)) axil_vif_t;

  //---------------------------------------------------------------------------
  // Transactions
  //---------------------------------------------------------------------------
  class axil_item extends uvm_sequence_item;
    rand bit          write;
    rand bit [AW-1:0] addr;
    rand bit [2:0]    prot;
    rand bit [DW-1:0] data;            // write data
    rand bit [SW-1:0] strb;
    rand int unsigned addr_delay;      // cycles before AW or AR
    rand int unsigned data_delay;      // cycles before W
    rand int unsigned resp_delay;      // cycles before BREADY or RREADY

    // Filled in by the monitor
    bit [DW-1:0] rdata;
    bit [1:0]    resp;
    int          order;                // writes: -1 W first, 0 same cycle, 1 AW first
    bit          backpressured;        // the response waited for READY
    bit          overlapped;           // the other direction was in flight

    int unsigned max_delay = 3;
    int unsigned err_pct   = 10;

    constraint c_delays { addr_delay <= max_delay; data_delay <= max_delay;
                          resp_delay <= max_delay; }
    constraint c_addr   { addr dist { [12'h000:12'h03F] := (100 - err_pct),
                                      [ERR_BASE:12'hFFF] := err_pct }; }

    `uvm_object_utils(axil_item)

    function new(string name = "axil_item");
      super.new(name);
    endfunction

    virtual function string convert2string();
      return $sformatf("%s addr=%03h prot=%0d data=%08h strb=%b rdata=%08h resp=%0d",
                       write ? "WR" : "RD", addr, prot, data, strb, rdata, resp);
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
    int unsigned waits;

    `uvm_object_utils(reg_item)

    function new(string name = "reg_item");
      super.new(name);
    endfunction
  endclass

  //---------------------------------------------------------------------------
  // AXI4-Lite agent
  //---------------------------------------------------------------------------
  typedef uvm_sequencer #(axil_item) axil_sequencer;

  // The address and data phases and the response phase of each direction run
  // in separate threads, so the next AW and W - or the next AR - go out while
  // the previous response is still waiting for READY, as AXI allows. That is
  // what exercises the bridge's rule that it may not issue a request while
  // that direction's response is owed.
  class axil_driver extends uvm_driver #(axil_item);
    `uvm_component_utils(axil_driver)
    axil_vif_t vif;
    mailbox #(axil_item) wr_mb, rd_mb, b_mb, r_mb;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      wr_mb = new(1);
      rd_mb = new(1);
      b_mb  = new();
      r_mb  = new();
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(axil_vif_t)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "axil_driver: no virtual interface")
    endfunction

    task wait_cycles(int unsigned n);
      repeat (n) begin @(posedge vif.clk); #1; end
    endtask

    task write_worker();
      axil_item it;
      forever begin
        wr_mb.get(it);
        @(posedge vif.clk); #1;
        fork
          begin
            wait_cycles(it.addr_delay);
            vif.awvalid = 1'b1;
            vif.awaddr  = it.addr;
            vif.awprot  = it.prot;
            forever begin
              @(negedge vif.clk);
              if (vif.awready) break;
              @(posedge vif.clk); #1;
            end
            @(posedge vif.clk); #1;
            vif.awvalid = 1'b0;
          end
          begin
            wait_cycles(it.data_delay);
            vif.wvalid = 1'b1;
            vif.wdata  = it.data;
            vif.wstrb  = it.strb;
            forever begin
              @(negedge vif.clk);
              if (vif.wready) break;
              @(posedge vif.clk); #1;
            end
            @(posedge vif.clk); #1;
            vif.wvalid = 1'b0;
          end
        join
        b_mb.put(it);
      end
    endtask

    task b_worker();
      axil_item it;
      forever begin
        b_mb.get(it);
        wait_cycles(it.resp_delay);
        vif.bready = 1'b1;
        forever begin
          @(negedge vif.clk);
          if (vif.bvalid) break;
          @(posedge vif.clk); #1;
        end
        @(posedge vif.clk); #1;
        vif.bready = 1'b0;
      end
    endtask

    task read_worker();
      axil_item it;
      forever begin
        rd_mb.get(it);
        @(posedge vif.clk); #1;
        wait_cycles(it.addr_delay);
        vif.arvalid = 1'b1;
        vif.araddr  = it.addr;
        vif.arprot  = it.prot;
        forever begin
          @(negedge vif.clk);
          if (vif.arready) break;
          @(posedge vif.clk); #1;
        end
        @(posedge vif.clk); #1;
        vif.arvalid = 1'b0;
        r_mb.put(it);
      end
    endtask

    task r_worker();
      axil_item it;
      forever begin
        r_mb.get(it);
        wait_cycles(it.resp_delay);
        vif.rready = 1'b1;
        forever begin
          @(negedge vif.clk);
          if (vif.rvalid) break;
          @(posedge vif.clk); #1;
        end
        @(posedge vif.clk); #1;
        vif.rready = 1'b0;
      end
    endtask

    task run_phase(uvm_phase phase);
      vif.awvalid <= 1'b0; vif.awaddr <= '0; vif.awprot <= '0;
      vif.wvalid  <= 1'b0; vif.wdata  <= '0; vif.wstrb  <= '0;
      vif.bready  <= 1'b0;
      vif.arvalid <= 1'b0; vif.araddr <= '0; vif.arprot <= '0;
      vif.rready  <= 1'b0;
      wait (vif.rst_n === 1'b1);
      fork
        write_worker();
        b_worker();
        read_worker();
        r_worker();
      join_none
      forever begin
        seq_item_port.get_next_item(req);
        if (req.write) wr_mb.put(req);
        else           rd_mb.put(req);
        seq_item_port.item_done();
      end
    endtask
  endclass

  class axil_monitor extends uvm_monitor;
    `uvm_component_utils(axil_monitor)
    axil_vif_t vif;
    uvm_analysis_port #(axil_item) wr_ap, rd_ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      wr_ap = new("wr_ap", this);
      rd_ap = new("rd_ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(axil_vif_t)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "axil_monitor: no virtual interface")
    endfunction

    task run_phase(uvm_phase phase);
      longint unsigned cycle = 0;
      longint unsigned aw_cycle [$], w_cycle [$];
      bit [AW-1:0] aw_addr [$], ar_addr [$];
      bit [2:0]    aw_prot [$], ar_prot [$];
      bit [DW-1:0] w_data [$];
      bit [SW-1:0] w_strb [$];
      bit          wr_over_q [$], rd_over_q [$];
      bit          b_wait = 0, r_wait = 0;
      bit          p_bvalid = 0, p_bready = 0, p_rvalid = 0, p_rready = 0;
      bit [1:0]    p_bresp = '0, p_rresp = '0;
      bit [DW-1:0] p_rdata = '0;
      forever begin
        @(negedge vif.clk);
        cycle++;
        if (vif.rst_n !== 1'b1) continue;
        // The subordinate's hold rules on B and R
        if (p_bvalid && !p_bready && !(vif.bvalid && vif.bresp == p_bresp))
          `uvm_error("AXI", "B changed before BREADY")
        if (p_rvalid && !p_rready && !(vif.rvalid && vif.rresp == p_rresp && vif.rdata == p_rdata))
          `uvm_error("AXI", "R changed before RREADY")
        p_bvalid = vif.bvalid; p_bready = vif.bready; p_bresp = vif.bresp;
        p_rvalid = vif.rvalid; p_rready = vif.rready; p_rresp = vif.rresp; p_rdata = vif.rdata;

        if (vif.awvalid && vif.awready) begin
          aw_cycle.push_back(cycle); aw_addr.push_back(vif.awaddr); aw_prot.push_back(vif.awprot);
          wr_over_q.push_back(1'b0);
        end
        if (vif.wvalid && vif.wready) begin
          w_cycle.push_back(cycle); w_data.push_back(vif.wdata); w_strb.push_back(vif.wstrb);
        end
        if (vif.arvalid && vif.arready) begin
          ar_addr.push_back(vif.araddr); ar_prot.push_back(vif.arprot);
          rd_over_q.push_back(1'b0);
        end
        // Several transactions of one direction can be outstanding: each
        // records whether the other direction was in flight during its life.
        if ((aw_addr.size() != 0 || w_data.size() != 0) && ar_addr.size() != 0) begin
          foreach (wr_over_q[i]) wr_over_q[i] = 1'b1;
          foreach (rd_over_q[i]) rd_over_q[i] = 1'b1;
        end
        if (vif.bvalid && !vif.bready) b_wait = 1;
        if (vif.rvalid && !vif.rready) r_wait = 1;

        if (vif.bvalid && vif.bready) begin
          axil_item t = axil_item::type_id::create("t");
          if (aw_addr.size() == 0 || w_data.size() == 0) begin
            `uvm_error("AXI", "write response without a write address and data")
          end else begin
            longint unsigned ca = aw_cycle.pop_front(), cw = w_cycle.pop_front();
            t.write = 1;
            t.addr  = aw_addr.pop_front();
            t.prot  = aw_prot.pop_front();
            t.data  = w_data.pop_front();
            t.strb  = w_strb.pop_front();
            t.resp  = vif.bresp;
            t.order = (ca < cw) ? 1 : (ca > cw) ? -1 : 0;
            t.backpressured = b_wait;
            t.overlapped    = wr_over_q.size() != 0 && wr_over_q.pop_front();
            wr_ap.write(t);
          end
          b_wait = 0;
        end
        if (vif.rvalid && vif.rready) begin
          axil_item t = axil_item::type_id::create("t");
          if (ar_addr.size() == 0) begin
            `uvm_error("AXI", "read data without a read address")
          end else begin
            t.write = 0;
            t.addr  = ar_addr.pop_front();
            t.prot  = ar_prot.pop_front();
            t.rdata = vif.rdata;
            t.resp  = vif.rresp;
            t.backpressured = r_wait;
            t.overlapped    = rd_over_q.size() != 0 && rd_over_q.pop_front();
            rd_ap.write(t);
          end
          r_wait = 0;
        end
      end
    endtask
  endclass

  class axil_agent extends uvm_agent;
    `uvm_component_utils(axil_agent)
    axil_sequencer sqr;
    axil_driver    drv;
    axil_monitor   mon;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sqr = axil_sequencer::type_id::create("sqr", this);
      drv = axil_driver::type_id::create("drv", this);
      mon = axil_monitor::type_id::create("mon", this);
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
    axil_vif_t vif;
    int unsigned ready_pct = 60;
    bit [DW-1:0] mem [bit [AW-1:0]];

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(axil_vif_t)::get(this, "", "vif", vif))
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
        forever begin
          @(posedge vif.clk); #1;
          vif.reg_ready = ($urandom_range(0, 99) < ready_pct);
        end
        // The read mux does not care about reg_write: the bridge must ignore
        // reg_rdata on a write.
        forever begin
          @(posedge vif.clk); #2;
          vif.reg_error = (vif.reg_addr >= ERR_BASE);
          vif.reg_rdata = read_word(vif.reg_addr);
        end
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
    axil_vif_t vif;
    uvm_analysis_port #(reg_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(axil_vif_t)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "reg_monitor: no virtual interface")
    endfunction

    task run_phase(uvm_phase phase);
      int unsigned waits = 0;
      forever begin
        @(negedge vif.clk);
        if (vif.rst_n !== 1'b1) begin
          waits = 0;
          continue;
        end
        if (vif.reg_valid && vif.reg_ready) begin
          reg_item t = reg_item::type_id::create("t");
          t.write = vif.reg_write;
          t.addr  = vif.reg_addr;
          t.wdata = vif.reg_wdata;
          t.strb  = vif.reg_strb;
          t.prot  = vif.reg_prot;
          t.rdata = vif.reg_rdata;
          t.error = vif.reg_error;
          t.waits = waits;
          ap.write(t);
          waits = 0;
        end else if (vif.reg_valid) begin
          waits++;
        end
      end
    endtask
  endclass

  //---------------------------------------------------------------------------
  // Scoreboard and coverage
  //---------------------------------------------------------------------------
  class axil_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(axil_scoreboard)
    uvm_tlm_analysis_fifo #(axil_item) wr_fifo, rd_fifo;
    uvm_tlm_analysis_fifo #(reg_item)  reg_fifo;
    int unsigned checks = 0;
    bit [DW-1:0] ref_mem [bit [AW-1:0]];   // independent of the responder's

    bit          cv_write, cv_error, cv_back, cv_over;
    int          cv_order;
    int unsigned cv_waits;

    covergroup cg;
      cp_kind  : coverpoint cv_write;
      cp_error : coverpoint cv_error;
      cp_order : coverpoint cv_order iff (cv_write) { bins w_first = {-1}; bins same = {0};
                                                     bins aw_first = {1}; }
      cp_back  : coverpoint cv_back;
      cp_over  : coverpoint cv_over;
      cp_waits : coverpoint cv_waits { bins none = {0}; bins one = {1}; bins many = {[2:$]}; }
      x_kind   : cross cp_kind, cp_error;
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg = new();
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      wr_fifo  = new("wr_fifo", this);
      rd_fifo  = new("rd_fifo", this);
      reg_fifo = new("reg_fifo", this);
    endfunction

    task run_phase(uvm_phase phase);
      reg_item  r;
      axil_item a;
      forever begin
        reg_fifo.get(r);
        if (r.write) wr_fifo.get(a);
        else         rd_fifo.get(a);
        check_pair(r, a);
      end
    endtask

    function void check_pair(reg_item r, axil_item a);
      bit [1:0] want_resp = r.error ? SLVERR : OKAY;
      checks++;
      if (r.addr != a.addr || r.prot != a.prot)
        `uvm_error("SB", $sformatf("request %03h/%0d does not match %s", r.addr, r.prot,
                                   a.convert2string()))
      if (r.error != (r.addr >= ERR_BASE))
        `uvm_error("SB", $sformatf("register error %0b at %03h", r.error, r.addr))
      if (a.resp != want_resp)
        `uvm_error("SB", $sformatf("response %0d, expected %0d: %s", a.resp, want_resp,
                                   a.convert2string()))
      if (r.write) begin
        if (r.wdata != a.data || r.strb != a.strb)
          `uvm_error("SB", $sformatf("write data %08h/%b, expected %08h/%b", r.wdata, r.strb,
                                     a.data, a.strb))
        if (!r.error) begin
          bit [DW-1:0] w = ref_mem.exists(r.addr) ? ref_mem[r.addr] : '0;
          for (int b = 0; b < SW; b++)
            if (r.strb[b]) w[8*b +: 8] = r.wdata[8*b +: 8];
          ref_mem[r.addr] = w;
        end
      end else begin
        bit [DW-1:0] want = (r.error || !ref_mem.exists(r.addr)) ? '0 : ref_mem[r.addr];
        if (r.wdata != '0 || r.strb != '0)
          `uvm_error("SB", "read request with data or strobes")
        if (a.rdata != want)
          `uvm_error("SB", $sformatf("read %03h returned %08h, expected %08h", r.addr, a.rdata, want))
      end
      cv_write = r.write;
      cv_error = r.error;
      cv_order = a.order;
      cv_back  = a.backpressured;
      cv_over  = a.overlapped;
      cv_waits = r.waits;
      cg.sample();
    endfunction

    function void check_phase(uvm_phase phase);
      if (!reg_fifo.is_empty() || !wr_fifo.is_empty() || !rd_fifo.is_empty())
        `uvm_error("SB", $sformatf("unmatched at the end: %0d requests, %0d writes, %0d reads",
                                   reg_fifo.used(), wr_fifo.used(), rd_fifo.used()))
    endfunction
  endclass

  //---------------------------------------------------------------------------
  // Environment
  //---------------------------------------------------------------------------
  class axil_env extends uvm_env;
    `uvm_component_utils(axil_env)
    axil_agent      agent;
    reg_responder   responder;
    reg_monitor     rmon;
    axil_scoreboard sb;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent     = axil_agent::type_id::create("agent", this);
      responder = reg_responder::type_id::create("responder", this);
      rmon      = reg_monitor::type_id::create("rmon", this);
      sb        = axil_scoreboard::type_id::create("sb", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      agent.mon.wr_ap.connect(sb.wr_fifo.analysis_export);
      agent.mon.rd_ap.connect(sb.rd_fifo.analysis_export);
      rmon.ap.connect(sb.reg_fifo.analysis_export);
    endfunction
  endclass

  //---------------------------------------------------------------------------
  // Sequences
  //---------------------------------------------------------------------------
  class axil_rand_seq extends uvm_sequence #(axil_item);
    `uvm_object_utils(axil_rand_seq)
    int unsigned n         = 100;
    int unsigned max_delay = 3;
    int unsigned err_pct   = 10;

    function new(string name = "axil_rand_seq");
      super.new(name);
    endfunction

    task body();
      repeat (n) begin
        req = axil_item::type_id::create("req");
        req.max_delay = max_delay;
        req.err_pct   = err_pct;
        start_item(req);
        if (!req.randomize()) `uvm_fatal("RAND", "axil_item randomisation failed")
        finish_item(req);
      end
    endtask
  endclass

  //---------------------------------------------------------------------------
  // Tests
  //---------------------------------------------------------------------------
  class axil_base_test extends uvm_test;
    `uvm_component_utils(axil_base_test)
    axil_env     env;
    int unsigned n_items   = 600;
    int unsigned ready_pct = 60;
    int unsigned max_delay = 3;
    int unsigned err_pct   = 10;
    bit          need_full_coverage = 1;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      uvm_config_db#(int unsigned)::set(this, "env.responder", "ready_pct", ready_pct);
      env = axil_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      axil_rand_seq seq = axil_rand_seq::type_id::create("seq");
      seq.n         = n_items;
      seq.max_delay = max_delay;
      seq.err_pct   = err_pct;
      phase.raise_objection(this);
      seq.start(env.agent.sqr);
      // Let the last write and read finish.
      wait (env.sb.checks == n_items);
      repeat (5) @(posedge env.agent.drv.vif.clk);
      phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      real cov = env.sb.cg.get_coverage();
      `uvm_info("TEST", $sformatf("%0d transactions checked, coverage %0.1f%%",
                                  env.sb.checks, cov), UVM_LOW)
      if (env.sb.checks != n_items)
        `uvm_error("TEST", $sformatf("checked %0d transactions of %0d", env.sb.checks, n_items))
      if (need_full_coverage && cov < 100.0)
        `uvm_error("TEST", $sformatf("coverage %0.1f%% is below 100%%", cov))
      if (rs.get_severity_count(UVM_ERROR) == 0 && rs.get_severity_count(UVM_FATAL) == 0)
        $display("** UVM TEST PASSED **");
    endfunction
  endclass

  class axil_random_test extends axil_base_test;
    `uvm_component_utils(axil_random_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
  endclass

  class axil_saturation_test extends axil_base_test;
    `uvm_component_utils(axil_saturation_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
      n_items   = 400;
      ready_pct = 100;
      max_delay = 0;
      err_pct   = 0;
      need_full_coverage = 0;   // no errors, no back-pressure, no wait states
    endfunction
  endclass

endpackage
