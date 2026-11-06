// main() for a coverage build of a SystemVerilog testbench.
//
// The same loop as the one `verilator --binary` generates, which does not
// write coverage in Verilator 5.020. run_svtb.py builds with --prefix Vsvtb.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
#include <memory>

#include "Vsvtb.h"
#include "verilated.h"
#include "verilated_cov.h"

int main(int argc, char** argv) {
    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->commandArgs(argc, argv);
    const std::unique_ptr<Vsvtb> topp{new Vsvtb{contextp.get()}};

    while (!contextp->gotFinish()) {
        topp->eval();
        if (!topp->eventsPending()) break;
        contextp->time(topp->nextTimeSlot());
    }

    topp->final();
    contextp->coveragep()->write();
    return 0;
}
