`timescale 1ns/1ps
module tb_bmp_fit_errors;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,start=0,valid=0,eof=0;
    reg [7:0] data=0;
    wire [7:0] error_code;
    wire commit;
    reg [7:0] bytes_in [0:69];
    integer i,k;
    bmp24_fit_decoder #(.OUTPUT_WIDTH(16),.OUTPUT_HEIGHT(12)) dut (
        .clk(clk),.rst_n(rst_n),.file_start(start),.file_size(32'd70),
        .file_valid(valid),.file_byte(data),.file_end(eof),.upstream_error(8'd0),
        .file_pause(),.pixel_ready(1'b1),.pixel_valid(),.pixel_rgb(),
        .top_down(),.frame_commit(commit),.bmp_error(error_code)
    );
    always @(posedge clk) if(rst_n && commit) $fatal(1,"invalid image committed");
    task initialize_header;
        begin
            for(i=0;i<70;i=i+1) bytes_in[i]=0;
            bytes_in[0]="B";bytes_in[1]="M";bytes_in[2]=70;
            bytes_in[10]=54;bytes_in[14]=40;
            bytes_in[18]=2;bytes_in[22]=2;
            bytes_in[26]=1;bytes_in[28]=24;
        end
    endtask
    task check_error(input integer length,input [7:0] expected);
        begin
            @(negedge clk);rst_n=0;valid=0;eof=0;
            repeat(3) @(negedge clk);
            rst_n=1;start=1;@(negedge clk);start=0;
            for(k=0;k<length;k=k+1) begin
                valid=1;data=bytes_in[k];@(negedge clk);
            end
            valid=0;eof=1;@(negedge clk);eof=0;
            repeat(5000) @(negedge clk);
            if(error_code!==expected)
                $fatal(1,"error got %h expected %h",error_code,expected);
            $display("PASS error %h bytes=%0d",expected,length);
        end
    endtask
    initial begin
        initialize_header();bytes_in[0]=0;check_error(70,8'h31);
        initialize_header();bytes_in[18]=0;check_error(70,8'h32);
        initialize_header();bytes_in[19]=8'h20;check_error(70,8'h32);
        initialize_header();bytes_in[26]=2;check_error(70,8'h33);
        initialize_header();bytes_in[28]=32;check_error(70,8'h34);
        initialize_header();bytes_in[30]=1;check_error(70,8'h35);
        initialize_header();bytes_in[10]=20;check_error(70,8'h36);
        initialize_header();check_error(60,8'h37);
        initialize_header();check_error(20,8'h37);
        $display("ALL_SCALER_ERROR_TESTS_PASS");$finish;
    end
endmodule
