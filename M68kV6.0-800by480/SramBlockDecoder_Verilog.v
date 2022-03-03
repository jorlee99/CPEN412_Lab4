module SramBlockDecoder_Verilog( 
		input unsigned [16:0] Address, // lower 17 lines of address bus from 68k
		input SRamSelect_H,				 // from main (top level) address decoder indicating 68k is talking to Sram
		
		// 4 separate block select signals that parition 256kbytes (128k words) into 4 blocks of 64k (32 k words)
		output reg Block0_H, 
		output reg Block1_H, 
		output reg Block2_H, 
		output reg Block3_H 
);	

	reg [3:0] Block_Sel;

	always@(*)	begin
	
		// default block selects are inactive - override as appropriate later
		
		//	Block0_H <= 0; 
		//	Block1_H <= 0;
		// Block2_H <= 0; 
	   // Block3_H <= 0;

		// decode the top two address lines plus SRamSelect to provide 4 block select signals
		// for 4 blocks of 64k bytes (32k words) to give 256k bytes in total
	
		// TODO
		// Using top 2 address lines and SRamSelect_H
		
		Block_Sel <= {3'b0, SRamSelect_H} << (Address[16:15]);
		
		{Block0_H, Block1_H, Block2_H, Block3_H} <= Block_Sel;
		
	end
endmodule
