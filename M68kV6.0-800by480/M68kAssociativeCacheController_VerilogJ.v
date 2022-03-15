///////////////////////////////////////////////////////////////////////////////////////
// Simple Associative Cache controller
//
// designed to work with TG68 (68000 based) cpu with 16 bit data bus and 32 bit address bus
// separate upper and lowe data stobes for individual byte and also 16 bit word access
//
// Copyright PJ Davies August 2017
// Check
///////////////////////////////////////////////////////////////////////////////////////


module M68kAssociativeCacheController_Verilog (
		input Clock,															// used to drive the state machine - state changes occur on positive edge
		input Reset_L,    													// active low reset 

		// signals to 68k
		
		input DramSelect68k_H, 												// active high signal indicating Dram is being addressed by 68000
		input unsigned [31:0] AddressBusInFrom68k,					// address bus from 68000
		input unsigned [15:0] DataBusInFrom68k,  						// data bus in from 68000
		output reg unsigned [15:0] DataBusOutTo68k,  				// data bus out from Cache controller back to 68000 (during read)
		input UDS_L,	   													// active low signal driven by 68000 when 68000 transferring data over data bit 15-8
		input LDS_L,	   													// active low signal driven by 68000 when 68000 transferring data over data bit 7-0
		input WE_L, 															// active low write signal, otherwise assumed to be read
		input AS_L,									
		input DtackFromDram_L,												// dtack back from Dram
		input CAS_Dram_L,														// cas to Dram so we can count 2 clock delays before 1st data
		input RAS_Dram_L,														// so we can detect difference between a read and a refresh command

		input unsigned [15:0] DataBusInFromDram, 						// data bus in from Dram
		output reg unsigned [15:0] DataBusOutToDramController,	// data bus out to Dram (during write)
		input unsigned [15:0] DataBusInFromCache,						// data bus in from Cache
		
		output reg UDS_DramController_L,									// active low signal driven by 68000 when 68000 transferring data over data bit 7-0
		output reg LDS_DramController_L,									// active low signal driven by 68000 when 68000 transferring data over data bit 15-8
		output reg DramSelectFromCache_L,	
		output reg WE_DramController_L,									// active low Dram controller write signal
		output reg AS_DramController_L,
		output reg DtackTo68k_L,											// Dtack back to 68k at end of operation
		
		// Cache memory write signals
		output reg unsigned [3:0] TagCache_WE_L,						// 4 bits for 4 blocks to store an address in Cache
		output reg unsigned [3:0] DataCache_WE_L,						// 4 bits for 4 blocks to store data in Cache
		output reg unsigned [3:0] ValidBit_WE_L,						// 4 bits for 4 blocks to store a valid bit
		
		output reg unsigned [31:0] AddressBusOutToDramController,	// address bus from Cache to Dram controller
		output reg unsigned [24:0] TagDataOut,								// 25 bit address to store in the tag Cache
		output reg unsigned [2:0] WordAddress,								// upto 8 words in a Cache line
		output reg ValidBitOut_H,												// indicates the cache line is valid
		output reg unsigned [2:0] Index,										// 3 bit Line for 8 
	
		input unsigned [3:0] ValidHit_H,									// indicates if any block in valid and a hit for the set
		input unsigned [3:0] Valid_H,										// indicates if any block in valid
		input unsigned [2:0] LRUBits_In,	
		output reg unsigned [2:0] LRUBits_Out,	
		output reg LRU_WE_L,

		// debugging only
		output unsigned [4:0] CacheState	
	);



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// States
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	parameter	Reset								= 5'b00000;								
	parameter	InvalidateCache 				= 5'b00001;
	parameter 	Idle 								= 5'b00010;
	parameter	CheckForCacheHit 				= 5'b00011;	
	parameter	ReadDataFromDramIntoCache	= 5'b00100;
	parameter	CASDelay1 						= 5'b00101;
	parameter	CASDelay2 						= 5'b00110;
	parameter	BurstFill 						= 5'b00111;
	parameter	EndBurstFill 					= 5'b01000;
	parameter	WriteDataToDram 				= 5'b01001;
	parameter	WaitForEndOfCacheRead		= 5'b01010;
	
	// 5 bit variables to hold current and next state of the state machine
	reg unsigned [4:0] CurrentState;					// holds the current state of the Cache controller
	reg unsigned [4:0] NextState; 						// holds the next state of the Cache controller
	
	// counter for the read burst fill
	reg unsigned [15:0] BurstCounter;					// counts for at least 8 during a burst Dram read also counts lines when flusing the cache
	reg BurstCounterReset_L;								// reset for the above counter
	
	// 2 bit register to hold the block number and a signla to store it 
	reg unsigned [1:0] ReplaceBlockNumber;				// register to hold the number of the block/way where new cache data will be loaded
	reg unsigned [1:0] ReplaceBlockNumberData;		// data to store in the above register
	reg LoadReplacementBlockNumber_H;					// signal to load the replceblocknumber with the new data above
	
	// signals for the least recently used bits utilised in cache replacement policy
	reg  LRUBits_Load_H;
	reg  unsigned [2:0]  LRUBits;

	
	
	// start
	assign CacheState = CurrentState;								// for debugging purposes only

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// concurrent process state registers
// this process RECORDS the current state of the system.
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
   always@(posedge Clock, negedge Reset_L)
	begin
		if(Reset_L == 0)
			CurrentState <= Reset ;
		else
			CurrentState <= NextState;	
	end
	
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Burst read counter: Used to provide a 3 bit address to the Data in the Cache during burst reads from Dram
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

	always@(posedge Clock)
	begin
		if(BurstCounterReset_L == 0) 						// synchronous reset
			BurstCounter <= 16'b0000000000000000 ;
		else
			BurstCounter <= BurstCounter + 1;			// else count
	end
	
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// register to store the Set Replacement Number/Block: Used to provide a 2 bit address to select a way/block
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

	always@(posedge Clock)
	begin
		if(LoadReplacementBlockNumber_H == 1) 
			ReplaceBlockNumber <= ReplaceBlockNumberData;			// store the chosen block number
	end
	
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// register to store the LRU block bits:
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////	

	always@(posedge Clock)
	begin
		if(LRUBits_Load_H == 1)
			LRUBits	<= LRUBits_In;			// store the chosen block number
	end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// next state and output logic
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////	
	
	always@(*)
	begin
		// start with default inactive values for everything and override as necessary, so we do not infer storage for signals inside this process
	
		DataBusOutTo68k 					<= DataBusInFromCache;
		DataBusOutToDramController 	<= DataBusInFrom68k;

		// default is to give the Dram the 68k's signals directly (unless we want to change something)	
		
		AddressBusOutToDramController[31:4]	<= AddressBusInFrom68k[31:4];
		AddressBusOutToDramController[3:1]	<= 3'b000;								// all reads to Dram have lower 3 address lines set to 0 for a Cache line regardless of 68k address
		AddressBusOutToDramController[0] 	<= 0;										// to avoid inferring a latch for this bit
		
		TagDataOut							<= AddressBusInFrom68k[31:7];				// tag is 25 bits
		Index									<= AddressBusInFrom68k[6:4];				// cache Line is 3 bits for 8 Lines 4 way cache
		
		UDS_DramController_L				<= UDS_L;
		LDS_DramController_L	   		<= LDS_L;
		WE_DramController_L 				<= WE_L;
		AS_DramController_L				<= AS_L;
		
		DtackTo68k_L						<= 1;												// don't supply until we are ready
		TagCache_WE_L 						<= 4'b1111;										// don't write Cache address to any block
		DataCache_WE_L 					<= 4'b1111;										// don't write Cache data to any block
		ValidBit_WE_L						<= 4'b1111;										// don't write valid data to any block
		ValidBitOut_H						<= 0;												// line invalid
		DramSelectFromCache_L 			<= 1;												// don't give the Dram controller a select signal since we might not always want to cycle the Dram if we have a hit during a read
		WordAddress							<= 3'b000;										// default is byte 0 in 8 byte Cache line	
		
		BurstCounterReset_L 				<= 1;												// default is that burst counter can run (and wrap around if needed), we'll control when to reset it		
		
		ReplaceBlockNumberData 			<= 2'b00;			
		LoadReplacementBlockNumber_H 	<= 0 ;											// don't latch by default
		LRUBits_Out							<= 3'b000;
		LRU_WE_L								<= 1;												// dont write	
		LRUBits_Load_H						<= 0;
		
		NextState 							<= Idle ;										// default is to go to this state
			
//////////////////////////////////////////////////////////////////
// Initial State following a reset
//////////////////////////////////////////////////////////////////
		
		if(CurrentState == Reset) 	begin	  												// if we are in the Reset state				
			BurstCounterReset_L 	<= 0;														// reset the burst counter (synchronously)
			NextState				<= InvalidateCache;									// go invalidate the cache
		end

///////////////////////////////////////////////////////////////////////////////////////////////////////////
// This state will invalidate the cache before entering idle state and go through each set clearing each block
///////////////////////////////////////////////////////////////////////////////////////////////////////////	

		else if(CurrentState == InvalidateCache) begin	  						
			
			// burst counter should now be 0 when we first enter this state, as it was reset in state above
			if(BurstCounter == 8) 														// if we have done all cache lines
				NextState 						<= Idle;
			
			else begin
				NextState						<= InvalidateCache;					// assume we stay here
				Index	 							<= BurstCounter[2:0];				// 3 bit Line address for Index for 8 set/lines of cache
				
				// clear the validity bits for each cache
				ValidBitOut_H 					<=	0;		
				ValidBit_WE_L					<= 4'b0000;
				
				// clear the address tags for each cache set
				TagDataOut						<= 25'b0000000000000000000000000;	
				TagCache_WE_L					<= 4'b0000;							// clear all tag bits in each Line
				
				// clear the LRU bits for each cache Line
				LRUBits_Out						<= 3'b000;
				LRU_WE_L							<= 0;
			end
		end

///////////////////////////////////////////////
// Main IDLE state: 
///////////////////////////////////////////////

		else if(CurrentState == Idle) begin									// if we are in the idle state				
			if(AS_L == 1'b0 && DramSelect68k_H == 1'b1) begin //if AS_L is active and DramSelect68_H  is active {
				// update LRU bits 
				// first we have to read LRU bits into the controller based on the selected Line 
				// (which is based on CPU address)
				LRUBits_Load_H <= 1'b1; //Activate LRUBits_Load_H // Load LRU bits for the line
				// if the 68k's access is a read
				if(WE_L == 1'b1) begin// if WE_L is high {
					UDS_DramController_L <= 1'b0; // activate UDS and LDS to the Dram Controller to grab both bytes from Cache or Dram 
					LDS_DramController_L <= 1'b0;// regardless of what 68k asks
					NextState <= CheckForCacheHit; // NextState = CheckForCacheHit;
				end
				else begin
					// must be a 68k write
					// if we are writing, and data is already in the cache (a hit), we should invalidate that block/line
					// so set the ValidBitOut_H to 0 in preparation for a write to the Valid bit if cache hit occurs
					ValidBitOut_H <= 1'b0; // ValidBitOut_H = 0;
					// if(ValidHit_H[3:0]  != 4'b0000)begin //if (any of the 4 ValidHit_H[3..0] bits are 1) // (indicating a hit for the block)
					// 	ValidBit_WE_L <= !ValidHit_H[3:0] ; //Activate the single corresponding ValidBit_WE_L to invalidate that line
					// end
					ValidBit_WE_L <= !ValidHit_H[3:0]; // made a change here
					// writes bypass the cache so start the dram controller to perform the write		
					DramSelectFromCache_L <= 1'b0;
					NextState <= WriteDataToDram;

				end
			end
		end
		
////////////////////////////////////////////////////////////////////////////////////////////////////
// Check if we have a Cache HIT. If so give data to 68k or if not, go generate a burst fill
// update the Least Recently Used Bits (LRUBits)
////////////////////////////////////////////////////////////////////////////////////////////////////

		else if(CurrentState == CheckForCacheHit) begin				// we are looking for a Cache hit			
			UDS_DramController_L <= 1'b0; // activate UDS and LDS to the Dram Controller to grab both bytes from Cache or Dram 
			LDS_DramController_L <= 1'b0;// regardless of what 68k asks
			// if any Block for the Set produces a valid cache hit, i.e. we found the data we are after.
			// test each of the 4 blocks to see if one of them has both a cache hit and a valid bit set. 
			// That will indentify the block containing the data we can use and give to the cpu
			if(ValidHit_H[3:0] != 4'b0000)begin //if any of the ValidHit_H[3..0] bits reports a valid hit {
				// if we have the data in the Cache give it to the 68k and return to idle state
				// remember defaults:DataBusOutTo68k = DataBusInFromCache,AddressBusOutToDram = AddressBusInFrom68k, 
				// also remember the cache block DATA MUX is automatically set to the block producing the valid Hit
				// use the lowest 3 bits of the 68k address bus to select the correct word in the line to give to 68k
				// give the 68k a Dtack and then wait for the end of the 68k read 
				WordAddress <= AddressBusInFrom68k[3:1]; //WordAddress = AddressBusInFrom68k[3..1];
				DtackTo68k_L <= 1'b0; //Activate DtackTo68k_L 
				NextState <= WaitForEndOfCacheRead; //NextState = WaitForEndOfCacheRead;
				if (LRUBits[1:0] == 2'b00)begin //if LRUBits[0] and LRUBits[1] are both 0
					LRUBits_Out <= {LRUBits[2],2'b11}; //set 3 bit LRUBits_Out to {LRUBits[2] concated with binary 11};
				end
				else if(LRUBits[1:0] == 2'b10)begin //else if LRUBits[0] is 0 and LRUBits[1] is 1 
					LRUBits_Out <= {LRUBits[2],2'b01}; //set 3 bit LRUBits_Out to {LRUBits[2] concated with binary 01} ;
				end
				else if(LRUBits[2] == 1'b0 && LRUBits[0] == 1'b1)begin //else if LRUBits[0] is 1 and LRUBits[2] is 0
					LRUBits_Out  <= {1'b1,LRUBits[1],1'b0};//set 3 bit LRUBits_Out to {1 concated with LRUBits[1] concated with 0};
				end
				else begin
					LRUBits_Out <= {1'b0,LRUBits[1],1'b0};//set 3 bit LRUBits_Out to {0 concated with LRUBits[1] concated with 0};
				end
				// Update/Write new LRU bits back to cache
				LRU_WE_L <= 1'b0; //Activate LRU_WE_L;
			end
			else begin // if no hit, then get data from dram and update LRU bits
				DramSelectFromCache_L <= 1'b0;//Activate DramSelectFromCache_L;
				// use the LRU bits to figure out which block in the line to replace
				// then update the LRU bits and save the replacement number for later
				// algorithm based on https://people.cs.clemson.edu/~mark/464/p_lru.txt
				if (LRUBits[1:0] == 2'b00)begin //if LRUBits[0] and LRUBits[1] are both 0 {
					ReplaceBlockNumberData <= 2'b00;//Set 2 bit ReplaceBlockNumberData to binary 00; // use block 0
					LRUBits_Out <= {LRUBits[2],2'b11};//Set 3 bit LRUBits_Out to {LRUBits[2] concated with binary 11} ;
				end
				else if (LRUBits[1:0] == 2'b10)begin//else if LRUBits[0] is 0 and LRUBits[1] is 1 {
					ReplaceBlockNumberData <= 2'b01; //Set 2 bit ReplaceBlockNumberData to binary 01; // use block 1
					LRUBits_Out <= {LRUBits[2],2'b01};//Set 3 bit LRUBits_Out to {LRUBits[2] concated with binary 01} ;
				end
				else if (LRUBits[2] == 1'b0 && LRUBits[0] == 1'b1)begin //else if LRUBits[0] is 1 and LRUBits[2] is 0 {
					ReplaceBlockNumberData <= 2'b10; //Set 2 bit ReplaceBlockNumberData to binary 10; // use block 2
					LRUBits_Out <= {1'b1,LRUBits[1],1'b0}; //Set 3 bit LRUBits_Out to {1 concated with LRUBits[1] concated with 0} ;
				end
				else begin
					ReplaceBlockNumberData <= 2'b11;//Set 2 bit ReplaceBlockNumberData to binary 11; // use block 3
					LRUBits_Out <= {1'b0,LRUBits[1],1'b0};//Set 3 bit LRUBits_Out to {0 concated wit LRUBits[1] concated with 0} ;
				end
				LRU_WE_L <= 1'b0;
				LoadReplacementBlockNumber_H <= 1'b1;
				NextState <= ReadDataFromDramIntoCache;
			end
		end

///////////////////////////////////////////////////////////////////////////////////////////////
// Got a Cache hit, so give the 68k the Cache data now then wait for the 68k to end bus cycle 
///////////////////////////////////////////////////////////////////////////////////////////////

		else if(CurrentState == WaitForEndOfCacheRead) begin		
			UDS_DramController_L <= 1'b0; // activate UDS and LDS to the Dram Controller to grab both bytes from Cache or Dram 
			LDS_DramController_L <= 1'b0;// regardless of what 68k asks
			// remember defaults:DataBusOutTo68k = DataBusInFromCache,AddressBusOutToDram = AddressBusInFrom68k, 
			// default NextState is Idle;
			// keep using use the lowest 3 bits of the 68k address bus to select the correct word 
			// in the line to give to 68k. Keep giving the 68k a Dtack and then wait for the end of the 68k read 
			WordAddress <= AddressBusInFrom68k[3:1];
			DtackTo68k_L <= 1'b0;
			if(AS_L == 1'b0)begin // made a change here
				NextState <= WaitForEndOfCacheRead;
			end

		end
			
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Didn't get a cache hit during read so
// Start of operation to Read from Dram State : Remember that CAS latency is 2 clocks before 1st item of burst data appears
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

		else if(CurrentState == ReadDataFromDramIntoCache) begin
			UDS_DramController_L <= 1'b0; // activate UDS and LDS to the Dram Controller to grab both bytes from Cache or Dram 
			LDS_DramController_L <= 1'b0;// regardless of what 68k asks
			// Kick start the Dram controller to perform a burst read and fill a Line in the cache
			// and stay in this state until a dram read command issued
			DramSelectFromCache_L <= 1'b0; //Activate DramSelectFromCache_L; // keep kicking Dram controller
			NextState <= ReadDataFromDramIntoCache;//NextState = ReadDataFromDramIntoCache ;
			if(CAS_Dram_L == 1'b0 && RAS_Dram_L == 1'b1)begin//if CAS_Dram_L is 0 and RAS_Dram_L is 1 // if "read" command (not "refresh")
				NextState <= CASDelay1; //NextState = CASDelay1 ; // move to next state
			end
			// Store the 68k's address bus in the Cache Tag to mark the fact we have the data at that address 
			// and move on to next state to get Dram data
			// By Default: TagDataOut set to AddressBusInFrom68k(31..7); // tag is 25 bits
			ValidBitOut_H <= 1'b1; //set ValidBitOut_H to 1; // output “valid” signal
			// identify which block we are going to store the new data in based on the LRU bits 
			if (ReplaceBlockNumber == 2'b00)begin//if 2 bit ReplaceBlockNumber is binary 00 {
				TagCache_WE_L[0] <= 1'b0; //Activate TagCache_WE_L[0]; // issue write signal to Tag block 0
				ValidBit_WE_L[0] <= 1'b0;//Activate ValidBit_WE_L[0]; // issue write signal to Valid block 0
			end
			else if (ReplaceBlockNumber == 2'b01)begin//if 2 bit ReplaceBlockNumber is binary 01 {
				TagCache_WE_L[1] <= 1'b0; //Activate TagCache_WE_L[1]; // issue write signal to Tag block 1
				ValidBit_WE_L[1] <= 1'b0;//Activate ValidBit_WE_L[1]; // issue write signal to Valid block 1
			end
			else if (ReplaceBlockNumber == 2'b10)begin//if 2 bit ReplaceBlockNumber is binary 10 {
				TagCache_WE_L[2] <= 1'b0; //Activate TagCache_WE_L[2]; // issue write signal to Tag block 2
				ValidBit_WE_L[2] <= 1'b0;//Activate ValidBit_WE_L[2]; // issue write signal to Valid block 2
			end
			else begin
				TagCache_WE_L[3] <= 1'b0; //Activate TagCache_WE_L[3]; // issue write signal to Tag block 3
				ValidBit_WE_L[3] <= 1'b0; //Activate ValidBit_WE_L[3]; // issue write signal to Valid block 3
			end
		end
						
///////////////////////////////////////////////////////////////////////////////////////
// Wait for 1st CAS clock (latency)
///////////////////////////////////////////////////////////////////////////////////////
			
		else if(CurrentState == CASDelay1) begin		
			UDS_DramController_L <= 1'b0; // activate UDS and LDS to the Dram Controller to grab both bytes from Cache or Dram 
			LDS_DramController_L <= 1'b0;// regardless of what 68k asks
			DramSelectFromCache_L <= 1'b0;//Activate DramSelectFromCache_L; // keep reading from Dram
			NextState <= CASDelay2;//NextState = CASDelay2 ; // go an wait for 2nd CAS clock latency
		end
		
///////////////////////////////////////////////////////////////////////////////////////
// Wait for 2nd CAS Clock Latency
///////////////////////////////////////////////////////////////////////////////////////
			
		else if(CurrentState == CASDelay2) begin						
			UDS_DramController_L <= 1'b0; // activate UDS and LDS to the Dram Controller to grab both bytes from Cache or Dram 
			LDS_DramController_L <= 1'b0;// regardless of what 68k asks
			DramSelectFromCache_L <= 1'b0;//Activate DramSelectFromCache_L; // keep reading from Dram
			// reset the burst counter to supply 3 bit burst address 0-7 to Cache memory
			BurstCounterReset_L <= 1'b0;//Activate BurstCounterReset_L;
			NextState <= BurstFill; //NextState = BurstFill ;

		end

/////////////////////////////////////////////////////////////////////////////////////////////
// Start of burst fill from Dram into Cache (data should be available at Dram in this  state)
/////////////////////////////////////////////////////////////////////////////////////////////
		
		else if(CurrentState == BurstFill) begin
			UDS_DramController_L <= 1'b0; // activate UDS and LDS to the Dram Controller to grab both bytes from Cache or Dram 
			LDS_DramController_L <= 1'b0;// regardless of what 68k asks
			DramSelectFromCache_L <= 1'b0;//Activate DramSelectFromCache_L; // keep reading from Dram
			// burst counter should now be 0 when we first enter this state, as reset was synchronous
			NextState <= BurstFill;
			if(BurstCounter == 16'd8)begin//if BurstCounter equals 8) // if we have read 8 words, it's time to stop
				NextState <= EndBurstFill;
			end
			else begin
				// Use burst counter to supply the 3 bit address to the data Cache
				WordAddress <= BurstCounter[2:0];//WordAddress = BurstCounter[2..0];
				if(ReplaceBlockNumber == 2'b00)begin//if 2 bit ReplaceBlockNumber is binary 00
					DataCache_WE_L[0] <= 1'b0;//activate DataCache_WE_L[0]; // write data signal to block 0
				end
				else if(ReplaceBlockNumber == 2'b01)begin//else if 2 bit ReplaceBlockNumber is binary 01 
					DataCache_WE_L[1] <= 1'b0;//activate DataCache_WE_L[1];   // write data signal to block 1
				end
				else if(ReplaceBlockNumber == 2'b10)begin//else if 2 bit ReplaceBlockNumber is binary 10
					DataCache_WE_L[2] <= 1'b0;//activate DataCache_WE_L[2]; // write data signal to block 2
				end
				else begin
					DataCache_WE_L[3] <= 1'b0;//activate DataCache_WE_L[3]; // write data signal to block 2
				end
			end
		end
			
///////////////////////////////////////////////////////////////////////////////////////
// End Burst fill and give the CPU the data from the cache
///////////////////////////////////////////////////////////////////////////////////////
		else if(CurrentState == EndBurstFill) begin							// wait for Dram case signal to go low
			UDS_DramController_L <= 1'b0; // activate UDS and LDS to the Dram Controller to grab both bytes from Cache or Dram 
			LDS_DramController_L <= 1'b0;// regardless of what 68k asks
			DramSelectFromCache_L <= 1'b1;//set DramSelectFromCache_L to 1; // deactivate Dram controller
			DtackTo68k_L <= 1'b0;//Activate DtackTo68k_L; // give dtack to 68k until end of 68k's bus cycle
			// get the data from the Cache corresponding the REAL CPU address we are reading from
			WordAddress <= AddressBusInFrom68k[3:1];//WordAddress  = AddressBusInFrom68k[3..1];
			DataBusOutTo68k <= DataBusInFromCache; //DataBusOutTo68k = DataBusInFromCache; // give data to cpu
			// now wait for the 68k to terminate the read, either remove AS_L or DRamSelect_H
			if(AS_L == 1'b1 || DramSelect68k_H == 1'b0)begin//if AS_L is 1 OR DramSelect68k_H is 0 
				NextState <= Idle;//NextState = Idle ; // go to Idle state and ending the Dram access
			end
			else begin
				NextState <= EndBurstFill;//NextState = EndBurstFill ; // else stay here
			end
		end
		
///////////////////////////////////////////////
// Write Data to Dram State (no Burst)
///////////////////////////////////////////////
		else if(CurrentState == WriteDataToDram) begin	  					// if we are writing data to Dram
			AddressBusOutToDramController <= AddressBusInFrom68k; //AddressBusOutToDramController = AddressBusInFrom68k;
			// Data Bus to Dram is already set to 68k's data bus out by default
			// AS_L, WE_L, UDS_L and LDS_L are already set to 68k's equivalent by default
			DramSelectFromCache_L <= 1'b0;//Activate DramSelectFromCache_L; // keep kicking the Dram controller to write
			DtackTo68k_L <= DtackFromDram_L;//DtackTo68k_L = DtackFromDram_L; // give the 68k the Dram controllers dtack
			// now wait for the 68k to terminate the write either remove AS_L or DRamSelect_H
			if(AS_L == 1'b1 || DramSelect68k_H == 1'b0)begin//if AS_L is 1 OR DramSelect68k_H is 0
				NextState <= Idle;//NextState = Idle ; // go to Idle state ending the Dram access
			end
			else begin
				NextState <= WriteDataToDram;//NextState = WriteDataToDram; // else stay here until the 68k finishes the write
			end

		end		
	end
endmodule
