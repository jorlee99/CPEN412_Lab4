LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.std_logic_unsigned.all;
USE ieee.std_logic_arith.all;

entity CacheDataMux is
	Port (
			ValidHit0_H, ValidHit1_H,ValidHit2_H, ValidHit3_H, ValidHit4_H, ValidHit5_H,ValidHit6_H, ValidHit7_H : in std_logic;
			Block0_In		: in std_logic_vector(15 downto 0);  		
			Block1_In		: in std_logic_vector(15 downto 0);  		
			Block2_In		: in std_logic_vector(15 downto 0);  		
			Block3_In		: in std_logic_vector(15 downto 0);
			Block4_In		: in std_logic_vector(15 downto 0);  		
			Block5_In		: in std_logic_vector(15 downto 0);  		
			Block6_In		: in std_logic_vector(15 downto 0);  		
			Block7_In		: in std_logic_vector(15 downto 0);  		


			DataOut		: out std_logic_vector(15 downto 0)
	);
end ;

architecture bhvr of CacheDataMux is
begin
	process(ValidHit0_H, ValidHit1_H, ValidHit2_H, ValidHit3_H, ValidHit4_H, ValidHit5_H, ValidHit6_H, ValidHit7_H, Block0_In, Block1_In, Block2_In, Block3_In, Block4_In, Block5_In, Block6_In, Block7_In)
	begin
		if(ValidHit0_H = '1') then
			DataOut <= Block0_In;
		elsif(ValidHit1_H = '1') then
			DataOut <= Block1_In;
		elsif(ValidHit2_H = '1') then
			DataOut <= Block2_In;
		elsif(ValidHit3_H = '1') then
			DataOut <= Block3_In;
		elsif(ValidHit4_H = '1') then
			DataOut <= Block4_In;
		elsif(ValidHit5_H = '1') then
			DataOut <= Block5_In;
		elsif(ValidHit6_H = '1') then
			DataOut <= Block6_In;
		else
			DataOut <= Block7_In;	
		end if;
	end process;
end ;
