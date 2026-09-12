`timescale 1ns/1ps
`default_nettype none

module ycore_memory #(
    parameter PROGRAM_FILE = "program.hex"
)(
    input  wire        clk,
    input  wire        reset,

    // Çekirdeklerin komut portları
    input  wire [31:0] i0_addr,
    input  wire [31:0] i1_addr,
    input  wire        i0_valid,
    input  wire        i1_valid,

    output reg  [31:0] i0_data,
    output reg  [31:0] i1_data,
    output reg         i0_error,
    output reg         i1_error,

    // Ortak veri portuna gelen istekler
    input  wire [1:0]  req,
    input  wire [1:0]  wr,
    input  wire [1:0]  atomic_req,

    input  wire [31:0] addr0,
    input  wire [31:0] addr1,
    input  wire [15:0] wdata0,
    input  wire [15:0] wdata1,

    output reg  [1:0]  ready,
    output reg  [1:0]  error,
    output reg  [15:0] rdata0,
    output reg  [15:0] rdata1
);

    // 128 KiB ROM: 0x00000000 - 0x0001FFFF
    reg [31:0] rom [0:32767];

    // 32 KiB RAM: 0x10000000 - 0x10007FFF
    reg [15:0] ram [0:16383];

    reg        turn;
    reg        selected;
    reg        have_request;

    reg [31:0] addr;
    reg [15:0] wdata;
    reg [15:0] read_value;

    reg        write_enable;
    reg        atomic_enable;
    reg        ram_hit;
    reg        rom_hit;
    reg        bad;

    // Bellek okumalarını always @* dışında tutmak,
    // Icarus Verilog'daki büyük sensitivity listelerini önler.
    wire [31:0] fetch0;
    wire [31:0] fetch1;
    wire [31:0] rom_value;
    wire [15:0] ram_value;

    assign fetch0    = rom[i0_addr[16:2]];
    assign fetch1    = rom[i1_addr[16:2]];
    assign rom_value = rom[addr[16:2]];
    assign ram_value = ram[addr[14:1]];

    integer k;

    // Program ROM'unu başlat.
    // RAM özellikle sıfırlanmaz; kullanılmadan önce yazılmalıdır.
    initial begin
        for (k = 0; k < 32768; k = k + 1)
            rom[k] = 32'h00000000;

        if (PROGRAM_FILE != "")
            $readmemh(PROGRAM_FILE, rom);
    end

    // İki bağımsız komut okuma portu.
    always @* begin
        i0_data  = 32'h00000000;
        i1_data  = 32'h00000000;
        i0_error = 1'b0;
        i1_error = 1'b0;

        if (i0_valid) begin
            if ((i0_addr[1:0] != 2'b00) ||
                (i0_addr >= 32'h00020000)) begin
                i0_error = 1'b1;
            end else begin
                i0_data = fetch0;
            end
        end

        if (i1_valid) begin
            if ((i1_addr[1:0] != 2'b00) ||
                (i1_addr >= 32'h00020000)) begin
                i1_error = 1'b1;
            end else begin
                i1_data = fetch1;
            end
        end
    end

    // Veri portu seçimi, adres kontrolü ve okuma cevabı.
    always @* begin
        have_request = (|req) && !reset;

        // İki çekirdek aynı anda isterse round-robin seçimi.
        if (req[0]) begin
            if (req[1])
                selected = turn;
            else
                selected = 1'b0;
        end else begin
            selected = 1'b1;
        end

        addr          = selected ? addr1  : addr0;
        wdata         = selected ? wdata1 : wdata0;
        write_enable  = wr[selected];
        atomic_enable = atomic_req[selected];

        ram_hit = (addr >= 32'h10000000) &&
                  (addr <  32'h10008000);

        rom_hit = (addr < 32'h00020000);

        // Veri erişimleri 2 bayta hizalı olmalı.
        // ROM'a yazma ve atomik takas yasaktır.
        bad = addr[0] ||
              (!ram_hit && !rom_hit) ||
              (rom_hit && (write_enable || atomic_enable));

        ready      = 2'b00;
        error      = 2'b00;
        rdata0     = 16'h0000;
        rdata1     = 16'h0000;
        read_value = 16'h0000;

        if (have_request) begin
            ready[selected] = 1'b1;
            error[selected] = bad;

            if (!bad) begin
                if (ram_hit)
                    read_value = ram_value;
                else if (addr[1])
                    read_value = rom_value[31:16];
                else
                    read_value = rom_value[15:0];
            end

            if (selected)
                rdata1 = read_value;
            else
                rdata0 = read_value;
        end
    end

    // Yazma işlemi ve arbitraj önceliği.
    // XCHG sırasında çekirdek eski değeri bu kenarda alır;
    // yeni değer aynı kenarda RAM'e yazılır.
    always @(posedge clk) begin
        if (reset) begin
            turn <= 1'b0;
        end else if (have_request) begin
            turn <= !selected;

            if (!bad && ram_hit && write_enable)
                ram[addr[14:1]] <= wdata;
        end
    end

endmodule

`default_nettype wire
