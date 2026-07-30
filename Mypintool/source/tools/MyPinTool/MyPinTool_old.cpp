#include "pin.H"
#include <fstream>
#include <iostream>

std::ofstream OutFile; // File to log indirect jumps
// Global variable to store the executable name
std::string executableName;

// Define the ImageLoad function
VOID ImageLoad(IMG img, VOID *v) {
    if (IMG_IsMainExecutable(img)) {
        executableName = IMG_Name(img);
        
    }
}

// Helper function to find the segment and image information for a given address
ADDRINT GetSegmentBaseAddress(ADDRINT addr, std::string &imgName, ADDRINT &imgBase) {
    ADDRINT segmentBase = 0;
    imgName = "Unknown";
    imgBase = 0;

    // Lock the client before accessing image information
    PIN_LockClient();
    for (IMG img = APP_ImgHead(); IMG_Valid(img); img = IMG_Next(img)) {
        for (SEC sec = IMG_SecHead(img); SEC_Valid(sec); sec = SEC_Next(sec)) {
            if (addr >= SEC_Address(sec) && addr < (SEC_Address(sec) + SEC_Size(sec))) {
                segmentBase = SEC_Address(sec);
                imgName = IMG_Name(img);
                ImageLoad(img, nullptr);
                imgBase = IMG_LowAddress(img);
                break;
            }
        }
        if (segmentBase != 0) {
            break;
        }
    }
    // Unlock the client after accessing image information
    PIN_UnlockClient();

    return segmentBase;
}

// Callback to log indirect jumps
void LogIndirectJump(ADDRINT ip, ADDRINT target) {
    std::string imgName;
    ADDRINT imgBase = 0;
    ADDRINT segmentBase = GetSegmentBaseAddress(ip, imgName, imgBase);
    if(imgName == executableName) {
    OutFile << "Indirect Jump: Source: 0x" << std::hex << ip
            << " -> Target: 0x" << std::hex << target;
    if (segmentBase != 0) {
        OutFile << ", Segment Base Address: 0x" << segmentBase
                << ", Image Base Address: 0x" << imgBase
                << ", Image Name: " << imgName;
    } else {
        OutFile << ", Base Address: Unknown";
    }
    OutFile << std::endl;
    }
}

// Instrumentation function for instructions
void Instruction(INS ins, void *v) {
    // Check if the instruction is an indirect jump
    if (INS_IsBranch(ins) && INS_IsIndirectControlFlow(ins) && !INS_IsCall(ins)) {
        // Insert a call to log the indirect jump
        INS_InsertCall(ins, IPOINT_TAKEN_BRANCH, (AFUNPTR)LogIndirectJump,
                       IARG_INST_PTR,           // Source address
                       IARG_BRANCH_TARGET_ADDR, // Target address
                       IARG_END);
    }
}

// Finalization function
void Fini(INT32 code, void *v) {
    OutFile.close();
}

// Main function
int main(int argc, char *argv[]) {
    // Initialize PIN
    if (PIN_Init(argc, argv)) {
        std::cerr << "PIN Initialization failed" << std::endl;
        return 1;
    }

    // Open output file
    OutFile.open("indirect_jumps_with_images.out");
    if (!OutFile.is_open()) {
        std::cerr << "Failed to open output file" << std::endl;
        return 1;
    }

    // Add instrumentation function
    INS_AddInstrumentFunction(Instruction, NULL);

   // Register the ImageLoad function for automatic calls during program execution
    IMG_AddInstrumentFunction(ImageLoad, nullptr);
    // Register finalization function
    PIN_AddFiniFunction(Fini, NULL);

    // Start the program
    PIN_StartProgram();

    return 0;
}

