`timescale 1ns/1ps
`default_nettype none

module YCore_8 (
    input  logic        clk,
    input  logic        rst,

    output logic [7:0]  instr_addr,
    input  logic [15:0] instr_data,

    output logic [7:0]  data_addr,
    output logic [7:0]  data_wdata,
    input  logic [7:0]  data_rdata,
    output logic        data_we,

    output logic        zero_flag,
    output logic        halted
);

    localparam logic [3:0]
        OP_NOP  = 4'h0,
        OP_LDI  = 4'h1,
        OP_ADD  = 4'h2,
        OP_SUB  = 4'h3,
        OP_AND  = 4'h4,
        OP_OR   = 4'h5,
        OP_XOR  = 4'h6,
        OP_SHL  = 4'h7,
        OP_SHR  = 4'h8,
        OP_LD   = 4'h9,
        OP_ST   = 4'hA,
        OP_JMP  = 4'hB,
        OP_JZ   = 4'hC,
        OP_JNZ  = 4'hD,
        OP_MOV  = 4'hE,
        OP_HALT = 4'hF;

    logic [7:0] regs [0:7];
    logic [7:0] pc;
    logic [7:0] pc_next;
    logic [7:0] writeback;
    logic       reg_we;
    logic       halt_request;

    wire [3:0] opcode = instr_data[15:12];
    wire [2:0] rd     = instr_data[11:9];
    wire [2:0] rs     = instr_data[8:6];
    wire [7:0] imm    = instr_data[7:0];

    assign instr_addr = pc;

    always_comb begin
        pc_next      = pc;
        writeback    = 8'h00;
        reg_we       = 1'b0;
        halt_request = 1'b0;

        data_addr    = 8'h00;
        data_wdata   = 8'h00;
        data_we      = 1'b0;

        if (!rst && !halted) begin
            pc_next = pc + 8'd1;

            case (opcode)
                OP_NOP: begin
                end

                OP_LDI: begin
                    writeback = imm;
                    reg_we    = 1'b1;
                end

                OP_ADD: begin
                    writeback = regs[rd] + regs[rs];
                    reg_we    = 1'b1;
                end

                OP_SUB: begin
                    writeback = regs[rd] - regs[rs];
                    reg_we    = 1'b1;
                end

                OP_AND: begin
                    writeback = regs[rd] & regs[rs];
                    reg_we    = 1'b1;
                end

                OP_OR: begin
                    writeback = regs[rd] | regs[rs];
                    reg_we    = 1'b1;
                end

                OP_XOR: begin
                    writeback = regs[rd] ^ regs[rs];
                    reg_we    = 1'b1;
                end

                OP_SHL: begin
                    writeback = regs[rd] << 1;
                    reg_we    = 1'b1;
                end

                OP_SHR: begin
                    writeback = regs[rd] >> 1;
                    reg_we    = 1'b1;
                end

                OP_LD: begin
                    data_addr = imm;
                    writeback = data_rdata;
                    reg_we    = 1'b1;
                end

                OP_ST: begin
                    data_addr  = imm;
                    data_wdata = regs[rd];
                    data_we    = 1'b1;
                end

                OP_JMP: begin
                    pc_next = imm;
                end

                OP_JZ: begin
                    if (zero_flag)
                        pc_next = imm;
                end

                OP_JNZ: begin
                    if (!zero_flag)
                        pc_next = imm;
                end

                OP_MOV: begin
                    writeback = regs[rs];
                    reg_we    = 1'b1;
                end

                OP_HALT: begin
                    pc_next      = pc;
                    halt_request = 1'b1;
                end

                default: begin
                    pc_next      = pc;
                    halt_request = 1'b1;
                end
            endcase
        end
    end

    integer i;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            pc        <= 8'h00;
            zero_flag <= 1'b0;
            halted    <= 1'b0;

            for (i = 0; i < 8; i = i + 1)
                regs[i] <= 8'h00;
        end else if (!halted) begin
            pc <= pc_next;

            if (reg_we) begin
                regs[rd]  <= writeback;
                zero_flag <= (writeback == 8'h00);
            end

            if (halt_request)
                halted <= 1'b1;
        end
    end

endmodule

`default_nettype wire
