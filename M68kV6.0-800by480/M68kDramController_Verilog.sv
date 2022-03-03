//////////////////////////////////////////////////////////////////////////////////////-
// Simple DRAM controller for the DE1 board, assuming a 50MHz controller/memory clock
// Assuming 64Mbytes SDRam organised as 32Meg x16 bits with 8192 rows (13 bit row addr
// 1024 columns (10 bit column address) and 4 banks (2 bit bank address)
// CAS latency is 2 clock periods
//
// designed to work with 68000 cpu using 16 bit data bus and 32 bit address bus
// separate upper and lower data stobes for individual byte and 16 bit word access
//
// Copyright PJ Davies June 2020
//////////////////////////////////////////////////////////////////////////////////////-


module M68kDramController_Verilog (
			input Clock,								// used to drive the state machine- stat changes occur on positive edge
			input Reset_L,     						// active low reset 
			input unsigned [31:0] Address,		// address bus from 68000
			input unsigned [15:0] DataIn,			// data bus in from 68000
			input UDS_L,								// active low signal driven by 68000 when 68000 transferring data over data bit 15-8
			input LDS_L, 								// active low signal driven by 68000 when 68000 transferring data over data bit 7-0
			input DramSelect_L,     				// active low signal indicating dram is being addressed by 68000
			input WE_L,  								// active low write signal, otherwise assumed to be read
			input AS_L,									// Address Strobe
			
			output reg unsigned[15:0] DataOut, 				// data bus out to 68000
			output reg SDram_CKE_H,								// active high clock enable for dram chip
			output reg SDram_CS_L,								// active low chip select for dram chip
			output reg SDram_RAS_L,								// active low RAS select for dram chip
			output reg SDram_CAS_L,								// active low CAS select for dram chip		
			output reg SDram_WE_L,								// active low Write enable for dram chip
			output reg unsigned [12:0] SDram_Addr,			// 13 bit address bus dram chip	
			output reg unsigned [1:0] SDram_BA,				// 2 bit bank address
			inout  reg unsigned [15:0] SDram_DQ,			// 16 bit bi-directional data lines to dram chip
			
			output reg Dtack_L,									// Dtack back to CPU at end of bus cycle
			output reg ResetOut_L,								// reset out to the CPU
	
			// Use only if you want to simulate dram controller state (e.g. for debugging)
			output reg [4:0] DramState
		); 	
		
		// WIRES and REGs
		reg  	[4:0] Command;										// 5 bit signal containing Dram_CKE_H, SDram_CS_L, SDram_RAS_L, SDram_CAS_L, SDram_WE_L

		reg	TimerLoad_H ;										// logic 1 to load Timer on next clock
		reg   TimerDone_H ;										// set to logic 1 when timer reaches 0
		reg 	unsigned	[15:0] Timer;							// 16 bit timer value
		reg 	unsigned	[15:0] TimerValue;					// 16 bit timer preload value

		reg	RefreshTimerLoad_H;								// logic 1 to load refresh timer on next clock
		reg   RefreshTimerDone_H ;								// set to 1 when refresh timer reaches 0
		reg 	unsigned	[15:0] RefreshTimer;					// 16 bit refresh timer value
		reg 	unsigned	[15:0] RefreshTimerValue;			// 16 bit refresh timer preload value

		reg   unsigned [4:0] CurrentState;					// holds the current state of the dram controller
		reg   unsigned [4:0] NextState;						// holds the next state of the dram controller
		
		reg  	unsigned [1:0] BankAddress;
		reg  	unsigned [12:0] DramAddress;
		
		reg	DramDataLatch_H;									// used to indicate that data from SDRAM should be latched and held for 68000 after the CAS latency period
		reg  	unsigned [15:0]SDramWriteData;
		
		reg  FPGAWritingtoSDram_H;								// When '1' enables FPGA data out lines leading to SDRAM to allow writing, otherwise they are set to Tri-State "Z"
		reg  CPU_Dtack_L;											// Dtack back to CPU
		reg  CPUReset_L;		
		
		// user reg
		reg [2:0] NopCounter;
		reg [4:0] refreshDone;

		// 5 bit Commands to the SDRam

		parameter PoweringUp = 5'b00000 ;					// take CKE & CS low during power up phase, address and bank address = dont'care
		parameter DeviceDeselect  = 5'b11111;				// address and bank address = dont'care
		parameter NOP = 5'b10111;								// address and bank address = dont'care
		parameter BurstStop = 5'b10110;						// address and bank address = dont'care
		parameter ReadOnly = 5'b10101; 						// A10 should be logic 0, BA0, BA1 should be set to a value, other addreses = value
		parameter ReadAutoPrecharge = 5'b10101; 			// A10 should be logic 1, BA0, BA1 should be set to a value, other addreses = value
		parameter WriteOnly = 5'b10100; 						// A10 should be logic 0, BA0, BA1 should be set to a value, other addreses = value
		parameter WriteAutoPrecharge = 5'b10100 ;			// A10 should be logic 1, BA0, BA1 should be set to a value, other addreses = value
		parameter AutoRefresh = 5'b10001;
	
		parameter BankActivate = 5'b10011;					// BA0, BA1 should be set to a value, address A11-0 should be value
		parameter PrechargeSelectBank = 5'b10010;			// A10 should be logic 0, BA0, BA1 should be set to a value, other addreses = don't care
		
		parameter PrechargeAllBanks = 5'b10010;			// A10 should be logic 1, BA0, BA1 are dont'care, other addreses = don't care
		parameter ModeRegisterSet = 5'b10000;				// A10=0, BA1=0, BA0=0, Address = don't care
		parameter ExtModeRegisterSet = 5'b10000;			// A10=0, BA1=1, BA0=0, Address = value
		
	
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////-
// Define some states for our dram controller add to these as required - only 5 will be defined at the moment - add your own as required
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////-
	

		parameter InitialisingState = 5'h0;
		parameter WaitingForPowerUpState = 5'h1;
		parameter IssueFirstNOP = 5'h2;
		parameter PrechargingAllBanks = 5'h3;
		parameter PrechargeNop = 5'h4;
		parameter RefreshState = 5'h5;
		parameter RefreshNop10Loop = 5'h6;
		parameter RefreshCheck = 5'h7;
		parameter ModeRegister = 5'h8;
		parameter ModeRegsiterNop = 5'h9;
		parameter RefreshTimerLoad = 5'hA;
		parameter SleepState = 5'hB;
		parameter RefreshPreCharge = 5'hC;
		parameter RefreshNop = 5'hD;
		parameter RefreshCommandExec = 5'hE;
		parameter RefreshNopLoop = 5'hF;
		parameter CASState = 5'h10;
		parameter WriteState = 5'h11;
		parameter ReadWriteState = 5'h12;
		parameter TerminateBus = 5'h13;
		parameter ReadState = 5'h14;
		parameter WriteEndWaitState = 5'h15;
		
		
		// TODO - Add your own states as per your own design

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// General Timer for timing and counting things: Loadable and counts down on each clock then produced a TimerDone signal and stops counting
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

	always_ff@(posedge Clock)
		if(TimerLoad_H == 1) 				// if we get the signal from another process to load the timer
			Timer = TimerValue ;			// Preload timer
		else if(Timer != 16'd0) 			// otherwise, provided timer has not already counted down to 0, on the next rising edge of the clock		
			Timer = Timer - 16'd1 ;		// subtract 1 from the timer value

	always_ff@(Timer) begin
		TimerDone_H = 0 ;					// default is not done
	
		if(Timer == 16'd0) 					// if timer has counted down to 0
			TimerDone_H = 1 ;				// output '1' to indicate time has elapsed
	end

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Refresh Timer: Loadable and counts down on each clock then produces a RefreshTimerDone signal and stops counting
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

	always_ff@(posedge Clock)
		if(RefreshTimerLoad_H == 1) 						// if we get the signal from another process to load the timer
			RefreshTimer  <= RefreshTimerValue ;		// Preload timer
		else if(RefreshTimer != 16'd0) 					// otherwise, provided timer has not already counted down to 0, on the next rising edge of the clock		
			RefreshTimer <= RefreshTimer - 16'd1 ;		// subtract 1 from the timer value

	always_ff@(RefreshTimer) begin
		RefreshTimerDone_H = 0 ;							// default is not done

		if(RefreshTimer == 16'd0) 								// if timer has counted down to 0
			RefreshTimerDone_H = 1 ;						// output '1' to indicate time has elapsed
	end
	
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////-
// concurrent process state registers
// this process RECORDS the current state of the system.
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

   always_ff@(posedge Clock, negedge Reset_L)begin
			if(Reset_L == 0)begin 							// asynchronous reset
				CurrentState <= InitialisingState ;
			end
			else begin
			CurrentState <= NextState;
			// these are the raw signals that come from the dram controller to the dram memory chip. 
			// This process expects the signals in the form of a 5 bit bus within the signal Command. The various Dram commands are defined above just beneath the architecture)

			SDram_CKE_H <= Command[4];			// produce the Dram clock enable
			SDram_CS_L  <= Command[3];			// produce the Dram Chip select
			SDram_RAS_L <= Command[2];			// produce the dram RAS
			SDram_CAS_L <= Command[1];			// produce the dram CAS
			SDram_WE_L  <= Command[0];			// produce the dram Write enable
			
			SDram_Addr  <= DramAddress;		// output the row/column address to the dram
			SDram_BA   	<= BankAddress;		// output the bank address to the dram

			// signals back to the 68000

			Dtack_L 		<= CPU_Dtack_L ;			// output the Dtack back to the 68000			ResetOut_L 	<= CPUReset_L ;			// output the Reset out back to the 68000
			ResetOut_L <= CPUReset_L;
			DramState <= CurrentState ;					// output current state - useful for debugging so you can see you state machine changing states etc

			// The signal FPGAWritingtoSDram_H can be driven by you when you need to turn on or tri-state the data bus out signals to the dram chip data lines DQ0-15
			// when you are reading from the dram you have to ensure they are tristated (so the dram chip can drive them)
			// when you are writing, you have to drive them to the value of SDramWriteData so that you 'present' your data to the dram chips
			// of course during a write, the dram WE signal will need to be driven low and it will respond by tri-stating its outputs lines so you can drive data in to it
			// remember the Dram chip has bi-directional data lines, when you read from it, it turns them on, when you write to it, it turns them off (tri-states them)
			if(FPGAWritingtoSDram_H == 1) 			// if CPU is doing a write, we need to turn on the FPGA data out lines to the SDRam and present Dram with CPU data 
				SDram_DQ	<= SDramWriteData ;
			else
				SDram_DQ	<= 16'bZZZZZZZZZZZZZZZZ;			// otherwise tri-state the FPGA data output lines to the SDRAM for anything other than writing to it
			
			end

	end	
	
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////-
// Concurrent process to Latch Data from Sdram after Cas Latency during read
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////-

// this process will latch whatever data is coming out of the dram data lines on the FALLING edge of the clock you have to drive DramDataLatch_H to logic 1
// remember there is a programmable CAS latency for the Zentel dram chip on the DE1 board it's 2 or 3 clock cycles which has to be programmed by you during the initialisation
// phase of the dram controller following a reset/power on
//
// During a read, after you have presented CAS command to the dram chip you will have to wait 2 clock cyles and then latch the data out here and present it back
// to the 68000 until the end of the 68000 bus cycle

	always_ff@(negedge Clock)
	begin
		if(DramDataLatch_H == 1)      			// asserted during the read operation
			DataOut <= SDram_DQ ;					// store 16 bits of data regardless of width - don't worry about tri state since that will be handled by buffers outside dram controller
	end
	
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////-
// next state and output logic
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////	
	always_ff@(posedge Clock, negedge Reset_L)begin
		if(Reset_L == 1'b0)begin
			CPUReset_L <= 1'b0;
			NopCounter <= 3'b0;
			refreshDone <= 5'h0;
		end
		else begin
		case(CurrentState)
		
			InitialisingState: begin
				CPUReset_L <= 1'b0;
				NopCounter <= 3'b0;
				refreshDone <= 5'h0;
			end

			RefreshNop10Loop: begin
				NopCounter <= NopCounter + 1'b1;
			end
			RefreshCheck: begin
				NopCounter <= 16'h0;
				refreshDone <= refreshDone + 5'h1;
			end
			ModeRegister: begin
				refreshDone <= 5'h0;//reset back to 0
			end
			ModeRegsiterNop:begin
				NopCounter <= NopCounter + 1'b1;
			end
			RefreshTimerLoad:begin
				NopCounter <= 16'h0;
			end
			RefreshNopLoop: begin
				NopCounter <= NopCounter + 1'b1;
			end
			SleepState: begin
				CPUReset_L <= 1'b1;
			end
		endcase
		end
	end
	always_comb
	begin
	
	// In Verilog/VHDL - you will recall - that combinational logic (i.e. logic with no storage) is created as long as you
	// provide a specific value for a signal in each and every possible path through a process
	// 
	// You can do this of course, but it gets tedious to specify a value for each signal inside every process state and every if-else test within those states
	// so the common way to do this is to define default values for all your signals and then override them with new values as and when you need to.
	// By doing this here, right at the start of a process, we ensure the compiler does not infer any storage for the signal, i.e. it creates
	// pure combinational logic (which is what we want)
	//
	// Let's start with default values for every signal and override as necessary, 
	//
	
		Command 	= NOP ;												// assume no operation command for Dram chip
		NextState = InitialisingState ;							// assume next state will always be idle state unless overridden the value used here is not important, we cimple have to assign something to prevent storage on the signal so anything will do
		
		TimerValue = 16'h0000;										// no timer value 
		RefreshTimerValue = 16'h0000 ;							// no refresh timer value
		TimerLoad_H = 0;												// don't load Timer
		RefreshTimerLoad_H = 0 ;									// don't load refresh timer
		DramAddress = 13'h0000 ;									// no particular dram address
		BankAddress = 2'b00 ;										// no particular dram bank address
		DramDataLatch_H = 0;										// don't latch data yet
		CPU_Dtack_L = 1 ;											// don't acknowledge back to 68000
		SDramWriteData = 16'h0000 ;								// nothing to write in particular
		FPGAWritingtoSDram_H = 0 ;								// default is to tri-state the FPGA data lines leading to bi-directional SDRam data lines, i.e. assume a read operation
		
		
		// put your current state/next state decision making logic here - here are a few states to get you started
		// during the initialising state, the drams have to power up and we cannot access them for a specified period of time (100 us)
		// we are going to load the timer above with a value equiv to 100us and then wait for timer to time out
			
		case(CurrentState)
				InitialisingState:begin //'h0
							TimerValue = 16'h0008;									// chose a value equivalent to 100us at 50Mhz clock - you might want to shorten it to somthing small for simulation purposes
							TimerLoad_H = 1 ;										// on next edge of clock, timer will be loaded and start to time out
							Command = PoweringUp ;									// clock enable and chip select to the Zentel Dram chip must be held low (disabled) during a power up phase
							NextState = WaitingForPowerUpState ;
						end
				WaitingForPowerUpState:begin//'h1
					Command = PoweringUp ;									// no DRam clock enable or CS while witing for 100us timer
					if(TimerDone_H == 1) 									// if timer has timed out i.e. 100us have elapsed
						NextState = IssueFirstNOP ;						// take CKE and CS to active and issue a 1st NOP command
					else
						NextState = WaitingForPowerUpState ;			// otherwise stay here until power up time delay finished
					end
				IssueFirstNOP:begin//'h2
							Command = NOP ;											// send a valid NOP command to the dram chip
							NextState = PrechargingAllBanks;
						end
				PrechargingAllBanks:begin//'h3
							DramAddress[10] = 1'b1;
							Command = PrechargeAllBanks;
							NextState = PrechargeNop;
						end
				PrechargeNop:begin //'h4
							Command = NOP;
							NextState = RefreshState;
						end
				RefreshState:begin//'h5
							Command = AutoRefresh;
							NextState = RefreshNop10Loop;
						end
				RefreshNop10Loop:begin//'h6
								Command = NOP;
								if(NopCounter < 3 && refreshDone < 5'h0a)begin
									NextState = RefreshNop10Loop;
								end
								else begin
									NextState = RefreshCheck;
								end
							end
				RefreshCheck:begin //'h7
							if (refreshDone < 5'h0a)
								begin
									NextState = RefreshState;
								end
							else 
								begin
									NextState = ModeRegister;
								end
						end
				ModeRegister:begin//'h8
							DramAddress = 13'h220;
							Command = ModeRegisterSet;
							NextState = ModeRegsiterNop;
						end
				ModeRegsiterNop:begin//'h9
								if(NopCounter < 3)begin
									Command = NOP;
									NextState = ModeRegsiterNop;
								end
								else begin
									NextState = RefreshTimerLoad;
								end
							end
				RefreshTimerLoad:begin//'hA
							RefreshTimerValue = 16'h176; // is this supposed to be 177?
//							RefreshTimerValue <= 16'h02;
							RefreshTimerLoad_H = 1;
							NextState = SleepState;
						end
				SleepState:begin //'hB
							Command = NOP;
							if(RefreshTimerDone_H) begin
								NextState = RefreshPreCharge;
							end
							else if(DramSelect_L  == 1'b0 && AS_L == 1'b0) begin
								NextState = ReadWriteState;
							end
							else begin
								Command = NOP;
								NextState = SleepState;
							end
						end
				RefreshPreCharge:begin //'hC
							DramAddress[10] = 1'b1;
							Command = PrechargeAllBanks;
							NextState = RefreshNop;
						end
				RefreshNop:begin //'hD
							Command = NOP;
							NextState = RefreshCommandExec;
						end
				RefreshCommandExec:begin //'hE
							Command = AutoRefresh;
							NextState = RefreshNopLoop;
						end
				RefreshNopLoop:begin //'hF
								if(NopCounter < 3)begin
									Command = NOP;
									NextState = RefreshNopLoop;
								end
								else begin
									NextState = RefreshTimerLoad;
								end
							end
				ReadWriteState: begin
										DramAddress = Address[23:11]; //row address
										BankAddress = Address[25:24]; //bank address
										Command = BankActivate;
										if(WE_L == 0) begin
											NextState = WriteState;
										end
										else begin
											NextState = ReadState;
										end
									end
				ReadState:begin
								DramAddress = {3'b001,Address[10:1]}; //column address
								BankAddress = Address[25:24]; //bank address
								Command = ReadAutoPrecharge;
								TimerValue = 16'h2;
								TimerLoad_H = 1 ;
								NextState = CASState;
							end
				CASState:begin
								Command = NOP;
								CPU_Dtack_L = 1'b0;
								if(TimerDone_H == 1)begin
									DramDataLatch_H =1;
									NextState = TerminateBus;
								end
									
								else
									NextState = CASState;
							end
				TerminateBus:begin
								Command = NOP;
								if(~UDS_L || ~LDS_L)begin
									CPU_Dtack_L = 1'b0;
									NextState = TerminateBus;
								end
								else
									NextState = SleepState;
							end
				
				WriteState:begin	// state to wait for either UDS or LDS to go low (they are active low)
								if(~UDS_L || ~LDS_L) begin
									
									CPU_Dtack_L = 0;
									DramAddress = {3'b001,Address[10:1]}; 
									BankAddress = Address[25:24];
									Command = WriteAutoPrecharge;
									// from the instructions: turn on the sdram controller bi-directional data lines so we can drive data into sdram memory
									SDramWriteData = DataIn;
									FPGAWritingtoSDram_H = 1; // to have the SDramWriteData driven on the bidirectional bus
									NextState = WriteEndWaitState;
								end
								else begin
									NextState = WriteState; // neither UDS or LDS are low, keep waiting in this state
								end
							end
				WriteEndWaitState:begin
								CPU_Dtack_L = 0;
								Command = NOP;
								SDramWriteData = DataIn;
								FPGAWritingtoSDram_H = 1;
								NextState = TerminateBus;

							end
			endcase

//		if(CurrentState == InitialisingState ) begin
//			TimerValue <= 16'h0000;									// chose a value equivalent to 100us at 50Mhz clock - you might want to shorten it to somthing small for simulation purposes
//			TimerLoad_H <= 1 ;										// on next edge of clock, timer will be loaded and start to time out
//			Command <= PoweringUp ;									// clock enable and chip select to the Zentel Dram chip must be held low (disabled) during a power up phase
//			NextState <= WaitingForPowerUpState ;				// once we have loaded the timer, go to a new state where we wait for the 100us to elapse
//		end
//		
//		else if(CurrentState == WaitingForPowerUpState) begin
//			Command <= PoweringUp ;									// no DRam clock enable or CS while witing for 100us timer
//			
//			if(TimerDone_H == 1) 									// if timer has timed out i.e. 100us have elapsed
//				NextState <= IssueFirstNOP ;						// take CKE and CS to active and issue a 1st NOP command
//			else
//				NextState <= WaitingForPowerUpState ;			// otherwise stay here until power up time delay finished
//		end
//		
//		else if(CurrentState == IssueFirstNOP) begin	 		// issue a valid NOP
//			Command <= NOP ;											// send a valid NOP command to the dram chip
//			NextState <= PrechargingAllBanks;
//		end		
		
		

		// add your other states and conditions and outputs here
		
	end	// always@ block
endmodule

