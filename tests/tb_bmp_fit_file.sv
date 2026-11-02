`timescale 1ns/1ps
// Verify an actual BMP against compare_scaling.py's independent golden frame.
module tb_bmp_fit_file;
    localparam W=640,H=480;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,start=0,valid=0,eof=0;
    reg [7:0] data=0;
    reg [31:0] size;
    reg [23:0] golden [0:W*H-1];
    string input_path,golden_path;
    integer handle,result,pos,j,n,value,count=0,writes=0,cycles=0,display_index;
    wire pause_input,pixel_valid,ready,top_down,commit,done,wr_en;
    wire [23:0] rgb;
    wire [7:0] error_code,memory_error;
    wire [20:0] wr_addr;
    wire [31:0] wr_data;
    wire [3:0] complete;
    reg saw_commit=0;
    bmp24_fit_decoder dut (
        .clk(clk),.rst_n(rst_n),.file_start(start),.file_size(size),
        .file_valid(valid),.file_byte(data),.file_end(eof),.upstream_error(8'd0),
        .file_pause(pause_input),.pixel_ready(ready),.pixel_valid(pixel_valid),
        .pixel_rgb(rgb),.top_down(top_down),.frame_commit(commit),.bmp_error(error_code)
    );
    media_frame_loader loader (
        .clk(clk),.rst_n(rst_n),.load_start(start),.image_index(2'd0),
        .pixel_valid(pixel_valid),.pixel_ready(ready),.pixel_rgb(rgb),
        .top_down(top_down),.frame_commit(commit),.decode_error(error_code),
        .load_busy(),.load_done(done),.image_complete(complete),.memory_error(memory_error),
        .controller_init_done(1'b1),.controller_busy(cycles%4000<2700),
        .refresh_active(cycles%97<7),.app_wr_en(wr_en),.app_wr_addr(wr_addr),
        .app_wr_mask(),.app_wr_data(wr_data)
    );
    always @(posedge clk) if(rst_n && !start) begin
        cycles=cycles+1;
        if(error_code || memory_error) $fatal(1,"decode=%h memory=%h",error_code,memory_error);
        if(cycles>80000000) $fatal(1,"file test timeout");
        if(pixel_valid) begin
            display_index=(top_down ? count/W : H-1-count/W)*W+count%W;
            if(count>=W*H || rgb!==golden[display_index])
                $fatal(1,"pixel %0d got=%h expected=%h",count,rgb,golden[display_index]);
            count=count+1;
        end
        if(wr_en) begin
            if(wr_addr>=W*H || wr_data!=={8'd0,golden[wr_addr]})
                $fatal(1,"SDRAM mismatch addr=%0d got=%h",wr_addr,wr_data);
            writes=writes+1;
        end
        if(commit) saw_commit=1;
    end
    initial begin
        if(!$value$plusargs("BMP=%s",input_path) || !$value$plusargs("GOLDEN=%s",golden_path))
            $fatal(1,"Pass +BMP=input.bmp +GOLDEN=area.hex");
        $readmemh(golden_path,golden);
        handle=$fopen(input_path,"rb");
        if(!handle) $fatal(1,"cannot open BMP");
        result=$fseek(handle,0,2);size=$ftell(handle);result=$fseek(handle,0,0);
        repeat(4) @(negedge clk);
        rst_n=1;start=1;@(negedge clk);start=0;
        pos=0;
        while(pos<size) begin
            while(pause_input) @(negedge clk);
            n=size-pos>512 ? 512 : size-pos;
            for(j=0;j<n;j=j+1) begin
                value=$fgetc(handle);
                if(value<0) $fatal(1,"unexpected EOF");
                data=value;valid=1;pos=pos+1;@(negedge clk);
            end
            valid=0;repeat(8) @(negedge clk);
        end
        $fclose(handle);
        eof=1;@(negedge clk);eof=0;
        wait(done);@(negedge clk);
        if(count!=W*H || writes!=W*H || !saw_commit || !complete[0])
            $fatal(1,"incomplete real-file frame");
        $display("REAL_BMP_AREA_REFERENCE_PASS bytes=%0d pixels=%0d cycles=%0d",size,count,cycles);
        $finish;
    end
endmodule
