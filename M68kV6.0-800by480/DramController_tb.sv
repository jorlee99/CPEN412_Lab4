module DramController_tb();

logic clk, Reset_L;

logic DramSelect_L, AS_L, UDS_L, WE_L;

M68kDramController_Verilog DUT(
	.Clock(clk),
	.Reset_L(Reset_L),
	.DramSelect_L(DramSelect_L),
	.AS_L(AS_L),
	.UDS_L(UDS_L),
	.WE_L(WE_L)
);

always begin
	#5; 
	clk = ~clk;
end

initial begin
clk = 1'b1;
Reset_L = 1'b1;
AS_L = 1'b0;
DramSelect_L = 1'b0;
UDS_L = 1'b1;
WE_L = 1'b1;

#10;

Reset_L = 1'b0;

#10;

Reset_L = 1'b1;


#40;

UDS_L = 1'b0;

#2000;

UDS_L = 1'b1;

#2000;



$stop;

end

endmodule

