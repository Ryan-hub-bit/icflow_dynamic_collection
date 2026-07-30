#include "pin.H"
#include <iostream>
#include <fstream>

// Create an output file to log the addresses
std::ofstream outFile("indirect_jumps_and_jump_tables.txt");

// Function to be called before the indirect jump occurs
VOID CaptureIndirectJump(ADDRINT targetAddress) {
    outFile << "Indirect jump to address: " << std::hex << targetAddress << std::dec << std::endl;
}

// Function to be called when a return instruction occurs
VOID CaptureReturn(ADDRINT targetAddress) {
    outFile << "Return jump to address: " << std::hex << targetAddress << std::dec << std::endl;
}

// Function to be called when a tail call instruction occurs
VOID CaptureTailCall(ADDRINT targetAddress) {
    outFile << "Tail call to address: " << std::hex << targetAddress << std::dec << std::endl;
}

// Function to capture jump table accesses
VOID CaptureJumpTableAccess(ADDRINT jumpTableAddr, ADDRINT targetAddr) {
    outFile << "Jump table access at address: " << std::hex << jumpTableAddr
            << " leading to target address: " << targetAddr << std::dec << std::endl;
}

// Instrumentation function for indirect jumps and jump tables
VOID Instruction(INS ins, VOID *v) {
    if (INS_IsIndirectControlFlow(ins)) {
        // Check for return or tail call instructions
        if (INS_IsRet(ins)) {
            INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)CaptureReturn, IARG_BRANCH_TARGET_ADDR, IARG_END);
        } else if (INS_HasFallThrough(ins)) {
            INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)CaptureIndirectJump, IARG_BRANCH_TARGET_ADDR, IARG_END);
        }
    }

    // Check for jump table accesses (e.g., `switch` statements)
    if (INS_IsMemoryRead(ins)) {
        // Check if the read is from a jump table (usually a pointer dereference or array index)
        if (INS_MemoryOperandIsRead(ins, 0) && INS_OperandIsMemory(ins, 0)) {
            ADDRINT jumpTableAddr = INS_MemoryOperandAddress(ins, 0); // Use MemoryOperandAddress instead
            INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)CaptureJumpTableAccess, IARG_MEMORYREAD_EA, IARG_MEMORYREAD_SIZE, IARG_PTR, &jumpTableAddr, IARG_END);
        }
    }
}

// Fini function to close the output file
VOID Fini(INT32 code, VOID *v) {
    outFile.close();
}

// Main function
int main(int argc, char *argv[]) {
    // Initialize Pin
    PIN_Init(argc, argv);

    // Register the Instruction function to be called for each instruction
    INS_AddInstrumentFunction(Instruction, 0);

    // Register the Fini function to close the output file when the program ends
    PIN_AddFiniFunction(Fini, 0);

    // Start the program
    PIN_StartProgram();
    return 0;
}
