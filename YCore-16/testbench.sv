`timescale 1ns/1ps
`default_nettype none

module testbench;

    logic clk;
    logic rst;

    wire [15:0] instr_addr;
    wire [23:0] instr_data;
    wire [15:0] data_addr;
    wire [15:0] data_wdata;
    wire [15:0] data_rdata;
    wire        data_we;
    wire        zero_flag;
    wire        halted;

    logic [23:0] rom [0:65535];
    logic [15:0] ram [0:65535];

    integer cycles;
    integer writes;
    integer i;

    YCore_16 dut (
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

    function automatic logic [23:0] rr (
        input logic [3:0] op,
        input logic [2:0] rd,
        input logic [2:0] rs
    );
        rr = {op, rd, rs, 14'b0};
    endfunction

    function automatic logic [23:0] ri (
        input logic [3:0]  op,
        input logic [2:0]  rd,
        input logic [15:0] imm
    );
        ri = {op, rd, 1'b0, imm};
    endfunction

    task automatic check16 (
        input string       name,
        input logic [15:0] actual,
        input logic [15:0] expected
    );
        if (actual !== expected)
            $fatal(1, "%s: expected=%04h, got=%04h",
                   name, expected, actual);
    endtask

    initial begin
        rst    = 1'b1;
        cycles = 0;
        writes = 0;

        for (i = 0; i < 65536; i = i + 1) begin
            rom[i] = 24'hF00000;
            ram[i] = 16'h0000;
        end

        rom[0]  = ri(4'h1, 3'd0, 16'd65530);  // LDI R0,65530
        rom[1]  = ri(4'h1, 3'd1, 16'd10);     // LDI R1,10
        rom[2]  = rr(4'h2, 3'd0, 3'd1);       // ADD R0,R1   -> 0004 (overflow)
        rom[3]  = ri(4'hA, 3'd0, 16'h8000);   // ST  R0,8000
        rom[4]  = ri(4'h9, 3'd2, 16'h8000);   // LD  R2,8000 -> 0004
        rom[5]  = rr(4'h3, 3'd2, 3'd1);       // SUB R2,R1   -> FFFA

        rom[6]  = rr(4'hE, 3'd3, 3'd2);       // MOV R3,R2   -> FFFA
        rom[7]  = rr(4'h4, 3'd3, 3'd1);       // AND R3,R1   -> 000A
        rom[8]  = rr(4'h5, 3'd3, 3'd0);       // OR  R3,R0   -> 000E
        rom[9]  = rr(4'h6, 3'd3, 3'd1);       // XOR R3,R1   -> 0004
        rom[10] = rr(4'h7, 3'd3, 3'd0);       // SHL R3      -> 0008
        rom[11] = rr(4'h8, 3'd2, 3'd0);       // SHR R2      -> 7FFD

        rom[12] = ri(4'hC, 3'd0, 16'hFF00);   // JZ FF00 (not taken, Z=0)

        rom[13] = ri(4'h1, 3'd4, 16'd3);      // LDI R4,3
        rom[14] = ri(4'h1, 3'd5, 16'd1);      // LDI R5,1
        rom[15] = rr(4'h3, 3'd4, 3'd5);       // SUB R4,R5           <-- loop start
        rom[16] = ri(4'hD, 3'd0, 16'd15);     // JNZ 15              (3 iterations)

        rom[17] = ri(4'hC, 3'd0, 16'd19);     // JZ 19 (taken, Z=1 after loop)
        rom[18] = ri(4'hA, 3'd1, 16'hEEEE);   // should not execute

        rom[19] = ri(4'hB, 3'd0, 16'h1234);   // JMP 1234 (address beyond 8 bits)
        rom[20] = ri(4'hA, 3'd1, 16'hEEEE);   // should not execute

        rom[16'h1234] = 24'h000000;                // NOP
        rom[16'h1235] = ri(4'hA, 3'd3, 16'h8001);  // ST R3,8001
        rom[16'h1236] = 24'hF00000;                // HALT

        rom[16'hFF00] = ri(4'hA, 3'd1, 16'hEEEE);  // bad-branch guard target
        rom[16'hFF01] = 24'hF00000;

        repeat (2) @(posedge clk);
        @(negedge clk);

        check16("Reset PC", instr_addr, 16'h0000);

        for (i = 0; i < 8; i = i + 1)
            check16($sformatf("Reset R%0d", i),
                    dut.regs[i], 16'h0000);

        if (halted !== 1'b0 || zero_flag !== 1'b0 ||
            data_we !== 1'b0)
            $fatal(1, "Reset control signals are incorrect");

        rst = 1'b0;

        while ((halted !== 1'b1) && cycles < 100) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;

            if (cycles == 3)
                check16("16-bit ADD overflow",
                        dut.regs[0], 16'h0004);

            if (cycles == 5)
                check16("Single-cycle LD",
                        dut.regs[2], 16'h0004);

            if (cycles == 6)
                check16("16-bit SUB result",
                        dut.regs[2], 16'hFFFA);
        end

        if (halted !== 1'b1)
            $fatal(1, "Timeout: HALT never asserted");

        if (cycles != 26)
            $fatal(1, "Cycle count: expected=26, got=%0d",
                   cycles);

        check16("R0", dut.regs[0], 16'h0004);
        check16("R1", dut.regs[1], 16'h000A);
        check16("R2", dut.regs[2], 16'h7FFD);
        check16("R3", dut.regs[3], 16'h0008);
        check16("R4", dut.regs[4], 16'h0000);
        check16("R5", dut.regs[5], 16'h0001);
        check16("R6", dut.regs[6], 16'h0000);
        check16("R7", dut.regs[7], 16'h0000);

        check16("RAM[8000]", ram[16'h8000], 16'h0004);
        check16("RAM[8001]", ram[16'h8001], 16'h0008);
        check16("Branch guard (untouched)", ram[16'hEEEE], 16'h0000);
        check16("HALT PC", instr_addr, 16'h1236);

        if (zero_flag !== 1'b1 || writes != 2)
            $fatal(1, "Zero flag or memory write count is incorrect");

        repeat (3) begin
            @(posedge clk);
            #1;

            check16("HALT PC stability", instr_addr, 16'h1236);

            if (data_we !== 1'b0 || halted !== 1'b1 || writes != 2)
                $fatal(1, "State changed while halted");
        end

        @(negedge clk);
        rst = 1'b1;
        #1;

        check16("Post-HALT reset PC", instr_addr, 16'h0000);

        for (i = 0; i < 8; i = i + 1)
            check16($sformatf("Post-HALT reset R%0d", i),
                    dut.regs[i], 16'h0000);

        if (halted !== 1'b0 || zero_flag !== 1'b0 ||
            data_we !== 1'b0)
            $fatal(1, "Reset after HALT failed");

        $display("PASS: All YCore-16 tests passed.");
        $finish;
    end

    initial begin
        #2000;
        $fatal(1, "Global simulation timeout");
    end

endmodule

`default_nettype wire
