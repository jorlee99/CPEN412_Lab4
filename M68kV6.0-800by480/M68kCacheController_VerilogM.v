///////////////////////////////////////////////////////////////////////////////////////
// Simple Cache controller
//
// designed to work with TG68 (68000 based) cpu with 16 bit data bus and 32 bit address bus
// separate upper and lowe data stobes for individual byte and also 16 bit word access
//
// Copyright PJ Davies August 2017
// reference code
///////////////////////////////////////////////////////////////////////////////////////

module M68kCacheController_Verilog (
		input Clock,											// used to drive the state machine - state changes occur on positive edge
		input Reset_L,     									// active low reset 
		input CacheHit_H,										// high when cache contains matching address during read
		input ValidBitIn_H,									// indicates if the cache line is valid

		// signals to 68k
		
		input DramSelect68k_H,     						// active high signal indicating Dram is being addressed by 68000
		input unsigned [31:0] AddressBusInFrom68k,  	// address bus from 68000
		input unsigned [15:0] DataBusInFrom68k, 		// data bus in from 68000
		output logic unsigned [15:0] DataBusOutTo68k, 	// data bus out from Cache controller back to 68000 (during read)
		input UDS_L,											// active low signal driven by 68000 when 68000 transferring data over data bit 15-8
		input LDS_L, 											// active low signal driven by 68000 when 68000 transferring data over data bit 7-0
		input WE_L,  											// active low write signal, otherwise assumed to be read
		input AS_L,
		input DtackFromDram_L,								// dtack back from Dram
		input CAS_Dram_L,										// cas to Dram so we can count 2 clock delays before 1st data
		input RAS_Dram_L,										// so we can detect diference between a read and a refresh command

		input unsigned [15:0] DataBusInFromDram, 							// data bus in from Dram
		output logic unsigned [15:0] DataBusOutToDramController, 		// data bus out to Dram (during write)
		input unsigned [15:0] DataBusInFromCache, 						// data bus in from Cache
		output logic UDS_DramController_L, 									// active low signal driven by 68000 when 68000 transferring data over data bit 7-0
		output logic LDS_DramController_L,										// active low signal driven by 68000 when 68000 transferring data over data bit 15-8
		output logic DramSelectFromCache_L,
		output logic WE_DramController_L,  									// active low Dram controller write signal
		output logic AS_DramController_L,
		output logic DtackTo68k_L, 												// Dtack back to 68k at end of operation
		
		// Cache memory write signals
		output logic TagCache_WE_L,												// to store an address in Cache
		output logic DataCache_WE_L,												// to store data in Cache
		output logic ValidBit_WE_L,												// to store a valid bit
		
		output logic unsigned [31:0] AddressBusOutToDramController,  	// address bus from Cache to Dram controller
		output logic unsigned [22:0] TagDataOut,  							// tag data to store in the tag Cache **Updated for 512 line
		output logic unsigned [2:0] WordAddress,								// upto 8 bytes in a Cache line
		output logic ValidBitOut_H,												// indicates the cache line is valid
		output logic unsigned [12:4] Index,										// 9 bit index in this example cache **Updated for 512 line

		output unsigned [4:0] CacheState										// for debugging
	);


/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Initialisation States
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	
	typedef enum logic unsigned [4:0] {
		Reset,
		InvalidateCache,
		Idle,
		CheckForCacheHit,
		ReadDataFromDramIntoCache,
		CASDelay1,
		CASDelay2,
		BurstFill,
		EndBurstFill,
		WriteDataToDram,
		WaitForEndOfCacheRead
	}statetype ;
	
	// 5 bit variables to hold current and next state of the state machine
	statetype   CurrentState;						// holds the current state of the Cache controller
	statetype   NextState;							// holds the next state of the Cache controller
	
	
	// counter for the read burst fill
	logic unsigned [15:0] BurstCounter;						// counts for at least 8 during a burst Dram read also counts lines when flusing the cache
	logic BurstCounterReset_L;									// reset for the above counter

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// concurrent process state registers
// this process RECORDS the current state of the system.
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

	assign CacheState = CurrentState;						// for debugging purposes only

   always_ff@(posedge Clock, negedge Reset_L)
	begin
		if(Reset_L == 1'b0) 
			CurrentState <= Reset ;
		else
			CurrentState <= NextState;	
	end
	
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Burst read counter: Used to provide a 3 bit address to the data Cache during burst reads from Dram and upto 2^12 cache lines
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

	always_ff@(posedge Clock)
	begin
		if(BurstCounterReset_L == 1'b0) 						// synchronous reset
			BurstCounter <= 16'b0;
		else
			BurstCounter <= BurstCounter + 1'b1;
	end
	
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// next state and output logic
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////	
	
	always_comb begin
		// start with default inactive values for everything and override as necessary, so we do not infer storage for signals inside this process
	
		NextState 						= Idle ;
		DataBusOutTo68k 				= DataBusInFromCache;
		DataBusOutToDramController = DataBusInFrom68k;

		// default is to give the Dram the 68k's signals directly (unless we want to change something)	
		
		AddressBusOutToDramController[31:4]	= AddressBusInFrom68k[31:4];
		AddressBusOutToDramController[3:1]  = 3'b0;								// all reads to Dram have lower 3 address lines set to 0 for a Cache line regardless of 68k address
		AddressBusOutToDramController[0] 	= 1'b0;								// to avoid inferring a latch for this bit
		
		TagDataOut						= AddressBusInFrom68k[31:9];
		Index								= AddressBusInFrom68k[8:4];			// cache index is 68ks address bits [8:4]
		
		UDS_DramController_L			= UDS_L;
		LDS_DramController_L	   	= LDS_L;
		WE_DramController_L 			= WE_L;
		AS_DramController_L			= AS_L;
		
		DtackTo68k_L					= 1'b1;									// don't supply until we are ready
		TagCache_WE_L 					= 1'b1;									// don't write Cache address
		DataCache_WE_L 				= 1'b1;									// don't write Cache data
		ValidBit_WE_L					= 1'b1;									// don't write valid data
		ValidBitOut_H					= 1'b0;									// line invalid
		DramSelectFromCache_L 		= 1'b1;									// don't give the Dram controller a select signal since we might not always want to cycle the Dram if we have a hit during a read
		WordAddress						= 3'b0;									// default is byte 0 in 8 byte Cache line	
		
		BurstCounterReset_L 			= 1'b1;									// default is that burst counter can run (and wrap around if needed), we'll control when to reset it		
		NextState 						= Idle ;							// default is to go to this state
		
	
		case(CurrentState)
//////////////////////////////////////////////////////////////////
// Initial State following a reset
//////////////////////////////////////////////////////////////////
		
			Reset: begin	  								// if we are in the Reset state				
				BurstCounterReset_L 				= 1'b0;							// reset the burst counter (synchronously)
				NextState							= InvalidateCache;				// go flush the cache
			end

/////////////////////////////////////////////////////////////////
// This state will flush the cache before entering idle state
/////////////////////////////////////////////////////////////////	
			InvalidateCache: begin	  						
				
				// burst counter should now be 0 when we first enter this state, as it was reset in state above
				
				if(BurstCounter == 16'd32) 											// if we have done all cache lines
					NextState 						= Idle;
				else begin
					NextState						= InvalidateCache;				// assume we stay here
					Index	 							= BurstCounter[4:0];	// 5 bit address for Index for 32 lines of cache
					
					// clear the validity bit for each cache line
					ValidBitOut_H 					=	1'b0;		
					ValidBit_WE_L					=  1'b0;
				end
			end

///////////////////////////////////////////////
// Main IDLE state: 
///////////////////////////////////////////////
			Idle: begin	  							// if we are in the idle state				

				if(AS_L== 1'b0 && DramSelect68k_H==1'b1)begin //NEED TO CHECK THIS STATE LOGIC. THINK IT IS WRONG
					if(WE_L==1'b1)begin
						UDS_DramController_L = 1'b0;//UDS and LDS
						LDS_DramController_L = 1'b0;
						NextState = CheckForCacheHit;
					end
					else begin
						if(ValidBitIn_H == 1'b1) begin
							ValidBitOut_H = 1'b0;
							ValidBit_WE_L = 1'b0;
						end
					DramSelectFromCache_L = 1'b0; //Activate DramSelectFromCache_L
					NextState = WriteDataToDram; 
					end
				end
			end

////////////////////////////////////////////////////////////////////////////////////////////////////
// Check if we have a Cache HIT. If so give data to 68k or if not, go generate a burst fill 
////////////////////////////////////////////////////////////////////////////////////////////////////

			CheckForCacheHit: begin	  			// if we are looking for Cache hit			
			UDS_DramController_L = 1'b0;
			LDS_DramController_L = 1'b0;
			
			if(CacheHit_H == 1'b1 && ValidBitIn_H == 1'b1) begin
			WordAddress = AddressBusInFrom68k[3:1];
			DtackTo68k_L = 1'b0;
			NextState = WaitForEndOfCacheRead;
			end
			
			else begin
			DramSelectFromCache_L = 1'b0;
			NextState = ReadDataFromDramIntoCache;
			end
			
			end	

///////////////////////////////////////////////////////////////////////////////////////////////
// Got a Cache hit, so give the 68k the Cache data now, then wait for the 68k to end bus cycle 
///////////////////////////////////////////////////////////////////////////////////////////////

			WaitForEndOfCacheRead: begin
			UDS_DramController_L = 1'b0;
			LDS_DramController_L = 1'b0;
			WordAddress = AddressBusInFrom68k[3:1];
			DtackTo68k_L = 1'b0;
			
			if(AS_L == 1'b0) begin
				NextState = WaitForEndOfCacheRead; 
			end

			end
			
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Start of operation to Read from Dram State : Remember that CAS latency is 2 clocks before 1st item of burst data appears
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

			ReadDataFromDramIntoCache: begin
			
			NextState = ReadDataFromDramIntoCache;
			
			if(CAS_Dram_L == 1'b0 && RAS_Dram_L == 1'b1) begin
				NextState = CASDelay1;
			end
			
			DramSelectFromCache_L = 1'b0;
			DtackTo68k_L = 1'b1;
				
			TagCache_WE_L = 1'b0;
				
			ValidBitOut_H = 1'b1;
				
			ValidBit_WE_L = 1'b0;
				
			UDS_DramController_L = 1'b0;
			LDS_DramController_L = 1'b0;

			end
						
///////////////////////////////////////////////////////////////////////////////////////
// Wait for 1st CAS clock (latency)
///////////////////////////////////////////////////////////////////////////////////////
			
			CASDelay1: begin						// wait for Dram case signal to go low
			UDS_DramController_L = 1'b0;
			LDS_DramController_L = 1'b0;
			
			DramSelectFromCache_L = 1'b0;
			
			DtackTo68k_L = 1'b1;
			
			NextState = CASDelay2;
			
			end
				
///////////////////////////////////////////////////////////////////////////////////////
// Wait for 2nd CAS Clock Latency
///////////////////////////////////////////////////////////////////////////////////////
			
			CASDelay2: begin						// wait for Dram case signal to go low
			UDS_DramController_L = 1'b0;
			LDS_DramController_L = 1'b0;
			
			DramSelectFromCache_L = 1'b0;
			
			DtackTo68k_L = 1'b1;
			
			BurstCounterReset_L = 1'b0;
			
			NextState = BurstFill;
			end

/////////////////////////////////////////////////////////////////////////////////////////////
// Start of burst fill from Dram into Cache (data should be available at Dram in this  state)
/////////////////////////////////////////////////////////////////////////////////////////////
		
			BurstFill: begin						// wait for Dram case signal to go low
			UDS_DramController_L = 1'b0;
			LDS_DramController_L = 1'b0;
			
			DramSelectFromCache_L = 1'b0;
			
			DtackTo68k_L = 1'b1;
			
			if(BurstCounter == 16'd8) begin
				NextState = EndBurstFill;
			end
			
			else begin
			WordAddress = BurstCounter[2:0];
			DataCache_WE_L = 1'b0;
			NextState = BurstFill;
			end
			
			end
			
///////////////////////////////////////////////////////////////////////////////////////
// End Burst fill
///////////////////////////////////////////////////////////////////////////////////////
			EndBurstFill: begin							// wait for Dram case signal to go low

			DramSelectFromCache_L = 1'b1;
			DtackTo68k_L = 1'b0;
			
			UDS_DramController_L = 1'b0;
			LDS_DramController_L = 1'b0;
			
			WordAddress = AddressBusInFrom68k[3:1];
			
			DataBusOutTo68k = DataBusInFromCache;
			
			if(AS_L == 1'b1 || DramSelect68k_H == 1'b0) begin
			NextState = Idle;
			end
			
			else begin
			NextState = EndBurstFill;
			end
			
			end

///////////////////////////////////////////////
// Write Data to Dram State (no Burst)
///////////////////////////////////////////////
			WriteDataToDram: begin	  					// if we are writing data to Dram

			AddressBusOutToDramController = AddressBusInFrom68k;
			
			DramSelectFromCache_L = 1'b0;
			
			DtackTo68k_L = DtackFromDram_L;
			
			if(AS_L == 1 || DramSelect68k_H == 0) begin
			NextState = Idle;
			end
			
			else begin
			NextState = WriteDataToDram;
			end
			
			
			end
			
			
		endcase
	end
endmodule