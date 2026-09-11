`timescale 1ns/1ps
`default_nettype none

module testbench;

    logic clk;
    logic rst;

    wire [7:0]  instr_addr;
    wire [15:0] instr_data;
    wire [7:0]  data_addr;
    wire [7:0]  data_wdata;
    wire [7:0]  data_rdata;
    wire        data_we;
    wire        zero_flag;
    wire        halted;

    logic [15:0] rom [0:255];
    logic [7:0]  ram [0:255];

    integer cycles;
    integer writes;
    integer i;

    YCore_8 dut (
        .clk        (clk),
        .rst        (rst),
        .instr_addr (instr_addr),
        .instr_data (instr_data),
        .data_addr  (data_addr),
        .data_wdata (data_wdata),
        .data_rdata (data_rdata),
        .data_we    (data_we),
        .zero_flag  (zero_flag),
        .halted     (halted)
    );

    assign instr_data = rom[instr_addr];
    assign data_rdata = ram[data_addr];

    always @(posedge clk) begin
        if (!rst && data_we) begin
            ram[data_addr] <= data_wdata;
            writes <= writes + 1;
        end
    end

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic logic [15:0] rr (
        input logic [3:0] op,
        input logic [2:0] rd,
        input logic [2:0] rs
    );
        rr = {op, rd, rs, 6'b000000};
    endfunction

    function automatic logic [15:0] ri (
        input logic [3:0] op,
        input logic [2:0] rd,
        input logic [7:0] imm
    );
        ri = {op, rd, 1'b0, imm};
    endfunction

    task automatic check8 (
        input string      name,
        input logic [7:0] actual,
        input logic [7:0] expected
    );
        if (actual !== expected)
            $fatal(1, "%s: expected=%02h, got=%02h",
                   name, expected, actual);
    endtask

    initial begin
        rst    = 1'b1;
        cycles = 0;
        writes = 0;

        for (i = 0; i < 256; i = i + 1) begin
            rom[i] = 16'hF000;
            ram[i] = 8'h00;
        end

        rom[0]  = ri(4'h1, 3'd0, 8'd250);  // LDI R0,250
        rom[1]  = ri(4'h1, 3'd1, 8'd10);   // LDI R1,10
        rom[2]  = rr(4'h2, 3'd0, 3'd1);    // ADD R0,R1   -> 04 (overflow)
        rom[3]  = ri(4'hA, 3'd0, 8'h80);   // ST  R0,80
        rom[4]  = ri(4'h9, 3'd2, 8'h80);   // LD  R2,80   -> 04
        rom[5]  = rr(4'h3, 3'd2, 3'd1);    // SUB R2,R1   -> FA
        rom[6]  = rr(4'hE, 3'd3, 3'd2);    // MOV R3,R2   -> FA
        rom[7]  = rr(4'h4, 3'd3, 3'd1);    // AND R3,R1   -> 0A
        rom[8]  = rr(4'h5, 3'd3, 3'd0);    // OR  R3,R0   -> 0E
        rom[9]  = rr(4'h6, 3'd3, 3'd1);    // XOR R3,R1   -> 04
        rom[10] = rr(4'h7, 3'd3, 3'd0);    // SHL R3      -> 08
        rom[11] = rr(4'h8, 3'd2, 3'd0);    // SHR R2      -> 7D

        rom[12] = ri(4'hC, 3'd0, 8'd250);  // JZ 250 (not taken, Z=0)

        rom[13] = ri(4'h1, 3'd4, 8'd3);    // LDI R4,3
        rom[14] = ri(4'h1, 3'd5, 8'd1);    // LDI R5,1
        rom[15] = rr(4'h3, 3'd4, 3'd5);    // SUB R4,R5           <-- loop start
        rom[16] = ri(4'hD, 3'd0, 8'd15);   // JNZ 15              (3 iterations)

        rom[17] = ri(4'hC, 3'd0, 8'd19);   // JZ 19 (taken, Z=1 after loop)
        rom[18] = ri(4'hA, 3'd1, 8'hEE);   // should not execute

        rom[19] = ri(4'hB, 3'd0, 8'd21);   // JMP 21
        rom[20] = ri(4'hA, 3'd1, 8'hEE);   // should not execute
        rom[21] = 16'h0000;                // NOP
        rom[22] = ri(4'hA, 3'd3, 8'h81);   // ST R3,81
        rom[23] = 16'hF000;                // HALT

        rom[250] = ri(4'hA, 3'd1, 8'hEE);  // bad-branch guard target
        rom[251] = 16'hF000;

        repeat (2) @(posedge clk);
        @(negedge clk);

        check8("Reset PC", instr_addr, 8'h00);
        for (i = 0; i < 8; i = i + 1)
            check8($sformatf("Reset R%0d", i), dut.regs[i], 8'h00);

        if (halted !== 1'b0 || zero_flag !== 1'b0 ||
            data_we !== 1'b0)
            $fatal(1, "Reset control signals are incorrect");

        rst = 1'b0;

        while ((halted !== 1'b1) && cycles < 100) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;

            if (cycles == 3)
                check8("ADD overflow result", dut.regs[0], 8'h04);

            if (cycles == 5)
                check8("Single-cycle LD", dut.regs[2], 8'h04);
        end

        if (halted !== 1'b1)
            $fatal(1, "Timeout: HALT never asserted");

        if (cycles != 26)
            $fatal(1, "Cycle count: expected=26, got=%0d", cycles);

        check8("R0", dut.regs[0], 8'h04);
        check8("R1", dut.regs[1], 8'h0A);
        check8("R2", dut.regs[2], 8'h7D);
        check8("R3", dut.regs[3], 8'h08);
        check8("R4", dut.regs[4], 8'h00);
        check8("R5", dut.regs[5], 8'h01);
        check8("R6", dut.regs[6], 8'h00);
        check8("R7", dut.regs[7], 8'h00);

        check8("RAM[80]", ram[8'h80], 8'h04);
        check8("RAM[81]", ram[8'h81], 8'h08);
        check8("Branch guard (untouched)", ram[8'hEE], 8'h00);
        check8("HALT PC", instr_addr, 8'd23);

        if (zero_flag !== 1'b1 || writes != 2)
            $fatal(1, "Zero flag or memory write count is incorrect");

        repeat (3) begin
            @(posedge clk);
            #1;
            check8("HALT PC stability", instr_addr, 8'd23);
            if (data_we !== 1'b0 || halted !== 1'b1 || writes != 2)
                $fatal(1, "State changed while halted");
        end

        @(negedge clk);
        rst = 1'b1;
        #1;

        check8("Post-HALT reset PC", instr_addr, 8'h00);
        for (i = 0; i < 8; i = i + 1)
            check8($sformatf("Post-HALT reset R%0d", i),
                   dut.regs[i], 8'h00);

        if (halted !== 1'b0 || zero_flag !== 1'b0 ||
            data_we !== 1'b0)
            $fatal(1, "Reset after HALT failed");

        $display("PASS: All YCore-8 tests passed.");
        $finish;
    end

    initial begin
        #2000;
        $fatal(1, "Global simulation timeout");
    end

endmodule

`default_nettype wire
