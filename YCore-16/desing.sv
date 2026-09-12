`include "memory.sv"
`timescale 1ns/1ps
`default_nettype none

// YCore-16 Duo / custom fixed-width ISA. Active-high synchronous reset.
module YCore_16 #(
    parameter PROGRAM_FILE = "program.hex"
)(
    input wire clk, input wire reset,
    output wire [1:0] halted, output wire [1:0] fault,
    output wire [31:0] pc0, output wire [31:0] pc1,
    output wire [7:0] fault_code0, output wire [7:0] fault_code1
);
    wire [31:0] ia [0:1];
    wire [31:0] ins [0:1];
    wire [1:0] iv, ie, req, wr, atomic_req, ready, err;
    wire [31:0] da [0:1];
    wire [15:0] wd [0:1], data_in [0:1];
    assign pc0=ia[0]; assign pc1=ia[1];
    ycore_cpu #(.CORE_ID(0), .RESET_PC(32'h00000000)) core0 (
        .clk(clk),.reset(reset),.i_addr(ia[0]),.i_valid(iv[0]),
        .i_data(ins[0]),.i_error(ie[0]),.d_req(req[0]),.d_write(wr[0]),
        .d_atomic(atomic_req[0]),.d_addr(da[0]),.d_wdata(wd[0]),
        .d_ready(ready[0]),.d_rdata(data_in[0]),.d_error(err[0]),
        .halted(halted[0]),.fault(fault[0]),.fault_code(fault_code0));
    ycore_cpu #(.CORE_ID(1), .RESET_PC(32'h00000100)) core1 (
        .clk(clk),.reset(reset),.i_addr(ia[1]),.i_valid(iv[1]),
        .i_data(ins[1]),.i_error(ie[1]),.d_req(req[1]),.d_write(wr[1]),
        .d_atomic(atomic_req[1]),.d_addr(da[1]),.d_wdata(wd[1]),
        .d_ready(ready[1]),.d_rdata(data_in[1]),.d_error(err[1]),
        .halted(halted[1]),.fault(fault[1]),.fault_code(fault_code1));
    ycore_memory #(.PROGRAM_FILE(PROGRAM_FILE)) mem (
        .clk(clk),.reset(reset),.i0_addr(ia[0]),.i1_addr(ia[1]),
        .i0_valid(iv[0]),.i1_valid(iv[1]),.i0_data(ins[0]),.i1_data(ins[1]),
        .i0_error(ie[0]),.i1_error(ie[1]),
        .req(req),.wr(wr),.atomic_req(atomic_req),
        .addr0(da[0]),.addr1(da[1]),.wdata0(wd[0]),.wdata1(wd[1]),
        .ready(ready),.error(err),.rdata0(data_in[0]),.rdata1(data_in[1]));
endmodule

// Per-core signed integer accelerator: 16x16 MAC and two packed int8 lanes.
// Accumulation wraps modulo 2^32. ReLU output saturates at signed int16 max.
module ycore_ai (
    input wire clk, input wire reset, input wire enable,
    input wire [1:0] operation, input wire [15:0] x, input wire [15:0] y,
    output logic signed [31:0] accumulator, output logic [15:0] relu
);
    wire signed [31:0] product = $signed(x) * $signed(y);
    wire signed [15:0] lane0 = $signed(x[7:0]) * $signed(y[7:0]);
    wire signed [15:0] lane1 = $signed(x[15:8]) * $signed(y[15:8]);
    wire signed [31:0] dot = {{16{lane0[15]}},lane0} + {{16{lane1[15]}},lane1};
    always @* begin
        if (accumulator < 0) relu=16'd0;
        else if (accumulator > 32'sd32767) relu=16'd32767;
        else relu=accumulator[15:0];
    end
    always @(posedge clk) begin
        if (reset) accumulator <= 0;
        else if (enable) case(operation)
            2'd0: accumulator <= 0;
            2'd1: accumulator <= accumulator + product;
            2'd2: accumulator <= accumulator + dot;
            2'd3: accumulator <= {x,y};
        endcase
    end
endmodule

module ycore_cpu #(
    parameter integer CORE_ID=0,
    parameter [31:0] RESET_PC=0
)(
    input wire clk, input wire reset,
    output wire [31:0] i_addr, output wire i_valid,
    input wire [31:0] i_data, input wire i_error,
    output wire d_req, output wire d_write, output wire d_atomic,
    output wire [31:0] d_addr, output wire [15:0] d_wdata,
    input wire d_ready, input wire [15:0] d_rdata, input wire d_error,
    output logic halted, output logic fault, output logic [7:0] fault_code
);
    localparam [1:0] FETCH=0, EXECUTE=1, MEMORY=2, STOP=3;
    logic [1:0] state;
    logic [31:0] pc, instruction;
    logic [15:0] r [0:15]; // r0 is hardwired to zero
    logic [31:0] a [0:3]; // true 32-bit byte addresses, independent of 16-bit ALU
    logic [31:0] pending_addr;
    logic [15:0] pending_data;
    logic [3:0] pending_rd;
    logic pending_write, pending_atomic;
    wire [7:0] op=instruction[31:24];
    wire [3:0] rd=instruction[23:20], ra=instruction[19:16], rb=instruction[15:12];
    wire [15:0] imm=instruction[15:0];
    wire [31:0] sext={{16{imm[15]}},imm};
    wire [31:0] branch_target=pc+32'd4+(sext<<2);
    wire ai_enable=state==EXECUTE && !reset &&
        (op==8'h50 || op==8'h51 || op==8'h52 || op==8'h56);
    wire [1:0] ai_operation=(op==8'h50)?2'd0:(op==8'h51)?2'd1:(op==8'h52)?2'd2:2'd3;
    wire signed [31:0] accumulator;
    wire [15:0] relu;
    ycore_ai ai(.clk(clk),.reset(reset),.enable(ai_enable),.operation(ai_operation),
        .x(r[ra]),.y(r[rb]),.accumulator(accumulator),.relu(relu));
    assign i_addr=pc;
    assign i_valid=state==FETCH && !reset;
    assign d_req=state==MEMORY && !reset;
    assign d_write=pending_write;
    assign d_atomic=pending_atomic;
    assign d_addr=pending_addr;
    assign d_wdata=pending_data;
    integer j;
    always @(posedge clk) begin
        if(reset) begin
            state<=FETCH; pc<=RESET_PC; instruction<=0;
            halted<=0; fault<=0; fault_code<=0;
            pending_addr<=0; pending_data<=0; pending_rd<=0;
            pending_write<=0; pending_atomic<=0;
            for(j=0;j<16;j=j+1) r[j]<=0;
            for(j=0;j<4;j=j+1) a[j]<=0;
        end else begin
            r[0]<=0;
            case(state)
                FETCH: begin
                    if(i_error) begin
                        fault<=1; halted<=1; fault_code<=8'h01; state<=STOP;
                    end else begin instruction<=i_data; state<=EXECUTE; end
                end
                EXECUTE: begin
                    pc<=pc+32'd4; state<=FETCH;
                    case(op)
                        8'h00: begin end // NOP
                        8'h01: begin halted<=1; state<=STOP; end
                        8'h02: if(rd!=0) r[rd]<=CORE_ID;
                        8'h03: if(rd!=0) r[rd]<=imm;
                        8'h04: if(rd!=0) r[rd]<=r[ra];
                        8'h10: if(rd!=0) r[rd]<=r[ra]+r[rb];
                        8'h11: if(rd!=0) r[rd]<=r[ra]-r[rb];
                        8'h12: if(rd!=0) r[rd]<=r[ra]&r[rb];
                        8'h13: if(rd!=0) r[rd]<=r[ra]|r[rb];
                        8'h14: if(rd!=0) r[rd]<=r[ra]^r[rb];
                        8'h15: if(rd!=0) r[rd]<=~r[ra];
                        8'h16: if(rd!=0) r[rd]<=r[ra]<<r[rb][3:0];
                        8'h17: if(rd!=0) r[rd]<=r[ra]>>r[rb][3:0];
                        8'h18: if(rd!=0) r[rd]<=$signed(r[ra])>>>r[rb][3:0];
                        8'h19: if(rd!=0) r[rd]<=r[ra]*r[rb];
                        8'h1a: if(rd!=0) r[rd]<=r[ra]+imm;
                        8'h1b: if(rd!=0) r[rd]<={15'd0,($signed(r[ra])<$signed(r[rb]))};
                        8'h1c: if(rd!=0) r[rd]<={15'd0,(r[ra]<r[rb])};
                        8'h20,8'h21,8'h22: begin
                            pending_addr<=a[ra[1:0]]+sext;
                            pending_data<=r[rd]; pending_rd<=rd;
                            pending_write<=op!=8'h20;
                            pending_atomic<=op==8'h22;
                            state<=MEMORY;
                        end
                        8'h30: a[rd[1:0]][15:0]<=imm;
                        8'h31: a[rd[1:0]][31:16]<=imm;
                        8'h32: a[rd[1:0]]<=a[rd[1:0]]+{{16{r[ra][15]}},r[ra]};
                        8'h33: if(rd!=0) r[rd]<=a[ra[1:0]][15:0];
                        8'h34: if(rd!=0) r[rd]<=a[ra[1:0]][31:16];
                        8'h40: if(r[rd]==r[ra]) pc<=branch_target;
                        8'h41: if(r[rd]!=r[ra]) pc<=branch_target;
                        8'h42: if($signed(r[rd])<$signed(r[ra])) pc<=branch_target;
                        8'h43: pc<=a[ra[1:0]]+sext;
                        8'h44: begin // CALL, link in r15:r14
                            {r[15],r[14]}<=pc+32'd4; pc<=a[ra[1:0]]+sext;
                        end
                        8'h45: pc<={r[15],r[14]};
                        8'h50,8'h51,8'h52,8'h56: begin end
                        8'h53: if(rd!=0) r[rd]<=accumulator[15:0];
                        8'h54: if(rd!=0) r[rd]<=accumulator[31:16];
                        8'h55: if(rd!=0) r[rd]<=relu;
                        default: begin
                            pc<=pc; fault<=1; halted<=1; fault_code<=8'h02; state<=STOP;
                        end
                    endcase
                end
                MEMORY: if(d_ready) begin
                    if(d_error) begin
                        halted<=1; fault<=1; fault_code<=8'h03; state<=STOP;
                    end else begin
                        if((!pending_write || pending_atomic) && pending_rd!=0)
                            r[pending_rd]<=d_rdata;
                        state<=FETCH;
                    end
                end
                STOP: begin end
                default: begin state<=STOP; halted<=1; fault<=1; fault_code<=8'hff; end
            endcase
        end
    end
endmodule
`default_nettype wire
