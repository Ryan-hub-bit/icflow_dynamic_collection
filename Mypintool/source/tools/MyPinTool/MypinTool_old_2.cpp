#include "pin.H"
#include <fstream>
#include <iostream>
#include <set>

std::ofstream OutFile; // File to log indirect jumps
std::string executableName; // Global variable to store the executable name
std::set<std::pair<ADDRINT, ADDRINT>> loggedJumps; // To track logged jumps (source, target)
ADDRINT imageHighAddr = 0;

// Define the ImageLoad function
VOID ImageLoad(IMG img, VOID *v) {
    if (IMG_IsMainExecutable(img)) {
        executableName = IMG_Name(img);
    }
}

// Helper function to find the segment and image information for a given address
ADDRINT GetSegmentBaseAddress(ADDRINT addr, std::string &imgName, ADDRINT &imgBase, ADDRINT &imgEnd) {
    ADDRINT segmentBase = 0;
    imgName = "Unknown";
    imgBase = 0;
    imgEnd = 0;

    PIN_LockClient();
    for (IMG img = APP_ImgHead(); IMG_Valid(img); img = IMG_Next(img)) {
        for (SEC sec = IMG_SecHead(img); SEC_Valid(sec); sec = SEC_Next(sec)) {
            if (SEC_Name(sec) == ".text") {
                if (addr >= SEC_Address(sec) && addr < (SEC_Address(sec) + SEC_Size(sec))) {
                    segmentBase = SEC_Address(sec);
                    imgName = IMG_Name(img);
                    ImageLoad(img, nullptr);  // Update executable name if it's the main executable
                    imgBase = IMG_LowAddress(img);
                    imgEnd = IMG_HighAddress(img);
                    imageHighAddr = imgEnd;
                }
            }
            if (segmentBase != 0) {
                break;
            }
        }
    }
    PIN_UnlockClient();

    return segmentBase;
}

// Callback to log indirect jumps, tail calls, and returns
void LogIndirectJump(ADDRINT ip, ADDRINT target, bool isReturn, bool isTailCall) {
    // If this jump (source, target) has already been logged, return immediately
    if (loggedJumps.find(std::make_pair(ip, target)) != loggedJumps.end()) {
        return; // Skip logging this jump again
    }

    PIN_LockClient();

    // Resolve the routine for the target address
    RTN rtn = RTN_FindByAddress(target);
    bool isValidRoutine = RTN_Valid(rtn); // Check if target is a valid function entry
    PIN_UnlockClient();

    std::string imgName;
    ADDRINT imgBase = 0, imgEnd = 0;
    ADDRINT segmentBase = GetSegmentBaseAddress(ip, imgName, imgBase, imgEnd);

    // Log only if the source is in the main executable
    if (imgName == executableName && target < imageHighAddr) {
        loggedJumps.insert(std::make_pair(ip, target));

        OutFile << (isReturn ? "Indirect Return:" : (isTailCall ? "Tail Call:" : "Indirect Jump:"))
                << " Source: 0x" << std::hex << ip
                << " -> Target: 0x" << std::hex << target << "\n";

        if (isValidRoutine) {
            OutFile << "  Function Name: " << RTN_Name(rtn) << "\n";
        }

        OutFile << "  Segment Base: 0x" << segmentBase
                << "  Image: " << imgName
                << " (Base: 0x" << imgBase << ", End: 0x" << imgEnd << ")\n\n";
    }
}

// Instrumentation function for instructions
void Instruction(INS ins, void *v) {
    // Check for indirect jumps (excluding calls)
    if (INS_IsIndirectControlFlow(ins) && !INS_IsCall(ins)) {
        bool isReturn = INS_IsRet(ins); // Check if the instruction is a return
        bool isTailCall = false; // Default to false; might need additional context for tail calls
        
        // Check if this is a tail call (heuristics: indirect jumps before returns)
        // In practice, you might refine this further based on the context (e.g., checking for return addresses)
        if (INS_HasFallThrough(ins) && !isReturn) {
            isTailCall = true; // Heuristic: if it has fall-through and isn't a return, assume tail call
        }

        // Insert a call to log the indirect jump or return
        INS_InsertCall(ins, IPOINT_TAKEN_BRANCH, (AFUNPTR)LogIndirectJump,
                       IARG_INST_PTR,           // Source address
                       IARG_BRANCH_TARGET_ADDR, // Target address
                       IARG_BOOL, isReturn,     // Whether this is a return
                       IARG_BOOL, isTailCall,   // Whether this is a tail call
                       IARG_END);
    }
}

// Finalization function
void Fini(INT32 code, void *v) {
    OutFile.close();
}

// Main function
int main(int argc, char *argv[]) {
    if (PIN_Init(argc, argv)) {
        std::cerr << "PIN Initialization failed" << std::endl;
        return 1;
    }

    OutFile.open("indirect_jumps_with_returns_and_tail_calls.out");
    if (!OutFile.is_open()) {
        std::cerr << "Failed to open output file" << std::endl;
        return 1;
    }

    INS_AddInstrumentFunction(Instruction, NULL);
    IMG_AddInstrumentFunction(ImageLoad, nullptr);
    PIN_AddFiniFunction(Fini, NULL);

    PIN_StartProgram();

    return 0;
}
