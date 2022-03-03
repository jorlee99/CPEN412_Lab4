
module Dtac_decoder_tb();

logic [31:0] Address;
logic out;

AddressDecoder_Verilog DUT (
	.Address(Address),
	.DramSelect_H(out)
);

always begin
	#10;	
	Address = Address + 32'h100;
end

initial begin

Address = 32'b0;

#2000;

while(Address < 32'hF400_0000)begin
	#1000;
end

$stop;

end

endmodule