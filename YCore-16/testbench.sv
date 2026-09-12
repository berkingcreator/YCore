`timescale 1ns/1ps
`default_nettype none
module testbench;
    logic clk=0, reset=1;
    always #5 clk=~clk;
    wire [1:0] halted,fault;
    wire [31:0] pc0,pc1;
    wire [7:0] fc0,fc1;
    YCore_16 dut(.clk(clk),.reset(reset),.halted(halted),.fault(fault),
        .pc0(pc0),.pc1(pc1),.fault_code0(fc0),.fault_code1(fc1));
    integer checks=0, conflicts=0, cycles, n, idx, t;
    reg [31:0] expected, v;
    reg [15:0] xv,yv;
    reg signed [31:0] sx,sy;
    function automatic [31:0] enc(input [7:0] op,input [3:0] rd,ra,input [15:0] imm);
        enc={op,rd,ra,imm};
    endfunction
    task automatic check(input logic condition,input string message);
        begin
            checks=checks+1;
            if(condition!==1'b1) $fatal(1,"FAIL: %s",message);
        end
    endtask
    task automatic fresh;
        begin
            @(negedge clk); reset=1;
            repeat(2) @(negedge clk);
            // Test-only ROM edits. Real hardware ROM is never writable.
            for(n=0;n<512;n=n+1) dut.mem.rom[n]=0;
            dut.mem.rom[0]=32'h01000000;
            dut.mem.rom[64]=32'h01000000;
            idx=0;
        end
    endtask
    task automatic emit(input [7:0] op,input [3:0] rd,ra,input [15:0] imm);
        begin dut.mem.rom[idx]=enc(op,rd,ra,imm); idx=idx+1; end
    endtask
    task automatic run_program;
        begin
            @(negedge clk); reset=0; cycles=0;
            while(halted!==2'b11 && cycles<2000) begin
                @(negedge clk); cycles=cycles+1;
            end
            check(halted===2'b11,"watchdog: both cores halt");
        end
    endtask
    always @(posedge clk) if(!reset) begin
        check(!(dut.ready==2'b11),"single data transaction per cycle");
        if(dut.req==2'b11) conflicts=conflicts+1;
    end
    initial begin
        if($test$plusargs("vcd")) begin
            $dumpfile("ycore16.vcd"); $dumpvars(0,testbench);
        end
        repeat(3) @(negedge clk);
        run_program();
        check(fault==0,"demo no fault");
        check(dut.mem.ram[0]===16'd0 && dut.mem.ram[8]===16'd1,"core IDs");
        check(dut.mem.ram[1]===16'd65 && dut.mem.ram[2]===16'd0,"core0 MAC+DOT");
        check(dut.mem.ram[3]===16'd65,"core0 ReLU");
        check(dut.mem.ram[9]===16'hfff1 && dut.mem.ram[10]===16'hffff,"negative MAC");
        check(dut.mem.ram[11]===16'd0,"negative ReLU");
        check(dut.core0.r[7]===16'd65 && dut.core1.r[7]===16'hfff1,"load after store");
        check(conflicts>0,"simultaneous data requests exercised");
        $display("PASS demo and dual-core contention");

        fresh();
        emit('h03,1,0,'hfffd); emit('h03,2,0,5);
        emit('h10,3,1,'h2000); emit('h11,4,1,'h2000);
        emit('h12,5,1,'h2000); emit('h13,6,1,'h2000);
        emit('h14,7,1,'h2000); emit('h15,8,1,0);
        emit('h16,9,2,'h2000); emit('h17,10,1,'h2000);
        emit('h18,11,1,'h2000); emit('h19,12,1,'h2000);
        emit('h1b,13,1,'h2000); emit('h1c,14,1,'h2000);
        emit('h1a,15,2,'hffff); emit('h03,0,0,'hffff); emit('h01,0,0,0);
        run_program();
        check(fault==0,"ALU no fault");
        check(dut.core0.r[0]===0,"r0 immutable");
        check(dut.core0.r[3]===16'd2 && dut.core0.r[4]===16'hfff8,"ADD SUB wrap");
        check(dut.core0.r[5]===5 && dut.core0.r[6]===16'hfffd && dut.core0.r[7]===16'hfff8,"bitwise");
        check(dut.core0.r[8]===2 && dut.core0.r[9]===160,"NOT SHL");
        check(dut.core0.r[10]===16'h07ff && dut.core0.r[11]===16'hffff,"SHR SAR");
        check(dut.core0.r[12]===16'hfff1,"MUL low");
        check(dut.core0.r[13]===1 && dut.core0.r[14]===0 && dut.core0.r[15]===4,"signed unsigned ADDI");
        $display("PASS integer ALU");

        fresh();
        emit('h03,1,0,3); // loop count
        emit('h1a,1,1,'hffff);
        emit('h41,1,0,'hfffe); // back to decrement
        emit('h40,1,0,1); // skip illegal opcode
        emit('hff,0,0,0);
        emit('h03,2,0,'hffff);
        emit('h42,2,0,1); // -1 < 0 -> skip fault
        emit('hff,0,0,0);
        emit('h30,1,0,'h0080); // a1 subroutine at 0x80
        emit('h44,0,1,0);
        emit('h04,4,3,0); emit('h01,0,0,0);
        idx=32; emit('h03,3,0,'hbeef); emit('h45,0,0,0);
        run_program();
        check(fault==0 && dut.core0.r[1]===0 && dut.core0.r[4]===16'hbeef,"branches CALL RET MOV");
        check({dut.core0.r[15],dut.core0.r[14]}===32'd40,"32-bit return address");
        $display("PASS branch loop and subroutine");

        fresh();
        emit('h31,2,0,'h1000); emit('h30,2,0,'h7ffe);
        emit('h03,1,0,'h1234); emit('h21,1,2,0); emit('h20,3,2,0);
        emit('h03,4,0,'hfffe); emit('h32,2,4,0);
        emit('h33,5,2,0); emit('h34,6,2,0);
        emit('h21,1,2,0); emit('h20,7,2,2);
        emit('h20,8,0,0); emit('h20,9,0,2); // two ROM halfwords
        emit('h01,0,0,0); run_program();
        check(fault==0 && dut.mem.ram[16383]===16'h1234,"RAM top boundary");
        check(dut.core0.r[3]===16'h1234 && dut.core0.r[7]===16'h1234,"32-bit effective address");
        check(dut.core0.r[5]===16'h7ffc && dut.core0.r[6]===16'h1000,"address add and extraction");
        check(dut.core0.r[8]===16'h1000 && dut.core0.r[9]===16'h3120,"ROM little endian data reads");
        $display("PASS address registers, RAM boundary, ROM reads");

        fresh();
        dut.mem.ram[0]=16'h1234;
        for(t=0;t<2;t=t+1) begin
            idx=t*64;
            emit('h31,0,0,'h1000); emit('h03,1,0,t==0 ? 16'haaaa : 16'hbbbb);
            emit('h22,1,0,0); emit('h01,0,0,0);
        end
        run_program();
        check(fault==0,"XCHG no fault");
        check(dut.core0.r[1]===16'h1234 && dut.core1.r[1]===16'haaaa && dut.mem.ram[0]===16'hbbbb,"serialized atomic exchange");
        $display("PASS atomic cross-core exchange");

        // Deterministic pseudo-random signed accelerator comparisons.
        v=32'h1a2b3c4d;
        for(t=0;t<24;t=t+1) begin
            v=v*32'd1664525+32'd1013904223; xv=v[15:0];
            v=v*32'd1664525+32'd1013904223; yv=v[15:0];
            sx={{16{xv[15]}},xv}; sy={{16{yv[15]}},yv}; expected=sx*sy;
            fresh();
            emit('h03,1,0,xv); emit('h03,2,0,yv);
            emit('h50,0,0,0); emit('h51,0,1,'h2000);
            emit('h53,3,0,0); emit('h54,4,0,0); emit('h55,5,0,0);
            emit('h01,0,0,0); run_program();
            check({dut.core0.r[4],dut.core0.r[3]}===expected,"random signed MAC");
            check(dut.core0.r[5]===(expected[31]?16'd0:expected>32767?16'd32767:expected[15:0]),"random saturated ReLU");
            sx={{24{xv[7]}},xv[7:0]}; sy={{24{yv[7]}},yv[7:0]}; expected=sx*sy;
            sx={{24{xv[15]}},xv[15:8]}; sy={{24{yv[15]}},yv[15:8]}; expected=expected+sx*sy;
            fresh();
            emit('h03,1,0,xv); emit('h03,2,0,yv);
            emit('h52,0,1,'h2000); emit('h53,3,0,0); emit('h54,4,0,0);
            emit('h01,0,0,0); run_program();
            check({dut.core0.r[4],dut.core0.r[3]}===expected,"random packed int8 dot product");
        end
        fresh();
        emit('h03,1,0,'h7fff); emit('h03,2,0,'hffff);
        emit('h56,0,1,'h2000); // bias = 0x7fffffff
        emit('h03,3,0,1); emit('h51,0,3,'h3000);
        emit('h53,4,0,0); emit('h54,5,0,0); emit('h55,6,0,0);
        emit('h01,0,0,0); run_program();
        check({dut.core0.r[5],dut.core0.r[4]}===32'h80000000 && dut.core0.r[6]===0,"bias and accumulator overflow wrap");
        $display("PASS 48 randomized AI cases, saturation and overflow");

        // Precise error classes, no invalid write side effects.
        for(t=0;t<6;t=t+1) begin
            fresh(); dut.mem.ram[0]=16'h55aa;
            case(t)
                0: emit('hff,0,0,0);
                1: begin emit('h30,0,0,1); emit('h43,0,0,0); end
                2: begin emit('h31,0,0,2); emit('h43,0,0,0); end
                3: begin emit('h31,0,0,'h1000); emit('h21,0,0,1); end
                4: emit('h21,0,0,0); // ROM write
                5: begin emit('h31,0,0,'h1000); emit('h30,0,0,'h8000); emit('h20,1,0,0); end
            endcase
            run_program();
            check(fault===2'b01,"only offending core faults");
            check(fc0===(t==0?8'd2:t<3?8'd1:8'd3),"fault category");
            check(dut.mem.ram[0]===16'h55aa,"invalid access does not corrupt RAM");
        end
        $display("PASS illegal opcode, fetch alignment/range, data alignment/range and ROM protection");
        $display("ALL TESTS PASSED: %0d checks; %0d contention cycles",checks,conflicts);
        $finish;
    end
    initial begin #1000000; $fatal(1,"global timeout"); end
endmodule
`default_nettype wire
