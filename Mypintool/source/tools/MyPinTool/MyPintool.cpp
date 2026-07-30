#include <pin.H>
#include <iostream>
#include <fstream>
#include <unordered_map>
#include <unordered_set>
#include <mutex>
#include <string>

// Output file for logging indirect jumps
std::ofstream OutputFile;

// Mutex for thread-safe access to shared data
std::mutex IndirectJumpMutex;

// Global variables to store main executable and `.text` section information
ADDRINT mainImageBase = 0;
ADDRINT mainImageHigh = 0;
ADDRINT textSectionBase = 0;
ADDRINT textSectionHigh = 0;
std::string mainImageName;

// Structure to track jump information
struct JumpInfo {
    ADDRINT address;                         // Address of the jump instruction
    std::string routine;                     // Routine name containing the jump
    std::unordered_set<ADDRINT> targets;     // Set of unique jump target addresses
    std::string insText;                     // Full instruction text
    int count;                               // Number of times this jump was executed
};

// Hash map to store unique jumps
std::unordered_map<ADDRINT, JumpInfo> IndirectJumps;

// Simplified indirect jump detection
BOOL IsIndirectJump(INS ins) {
    return INS_IsIndirectControlFlow(ins) && !INS_IsCall(ins);
}

// Track indirect jumps within `.text` section
VOID TrackIndirectJump(ADDRINT ip, CONTEXT* ctxt, ADDRINT target, const std::string* insText) {
    if (ip >= textSectionBase && ip < textSectionHigh) {
        std::lock_guard<std::mutex> lock(IndirectJumpMutex);
        auto& jumpInfo = IndirectJumps[ip];

        if (jumpInfo.count == 0) {
            jumpInfo.address = ip;
            jumpInfo.insText = *insText;

            PIN_LockClient();
            RTN rtn = RTN_FindByAddress(ip);
            jumpInfo.routine = RTN_Valid(rtn) ? RTN_Name(rtn) : "Unknown";
            PIN_UnlockClient();
        }

        jumpInfo.targets.insert(target); // Add the target to the set
        jumpInfo.count++;
    }
}

// Load the image and identify the main executable and `.text` section
VOID ImageLoad(IMG img, VOID* v) {
    if (IMG_IsMainExecutable(img)) {
        mainImageBase = IMG_LowAddress(img);
        mainImageHigh = IMG_HighAddress(img);
        mainImageName = IMG_Name(img);

        std::cout << "Main Executable: " << mainImageName << std::endl;
        std::cout << "Image Base Address: 0x" << std::hex << mainImageBase << std::endl;
        std::cout << "Image High Address: 0x" << mainImageHigh << std::endl;

        // Find `.text` section range
        for (SEC sec = IMG_SecHead(img); SEC_Valid(sec); sec = SEC_Next(sec)) {
            if (SEC_Name(sec) == ".text") {
                textSectionBase = SEC_Address(sec);
                textSectionHigh = textSectionBase + SEC_Size(sec);
                std::cout << ".text Section Base: 0x" << std::hex << textSectionBase << std::endl;
                std::cout << ".text Section High: 0x" << textSectionHigh << std::endl;
                break;
            }
        }

        if (textSectionBase == 0 && textSectionHigh == 0) {
            std::cerr << "Error: Could not find .text section in the main executable!" << std::endl;
        }
    }
}

// Finalize and log the results
VOID Fini(INT32 code, VOID* v) {
    if (OutputFile.is_open()) {
        OutputFile << "Indirect Jumps in " << mainImageName << ":\n";
        OutputFile << "Image Base Address: 0x" << std::hex << mainImageBase << "\n";
        OutputFile << "Image High Address: 0x" << mainImageHigh << "\n";
        OutputFile << ".text Section Base: 0x" << textSectionBase << "\n";
        OutputFile << ".text Section High: 0x" << textSectionHigh << "\n";
        OutputFile << "-----------------------------------\n";
        
        std::lock_guard<std::mutex> lock(IndirectJumpMutex);
        for (const auto& entry : IndirectJumps) {
            const auto& jumpInfo = entry.second;
            OutputFile << "Address: 0x" << std::hex << jumpInfo.address 
                       << " | Routine: " << jumpInfo.routine 
                       << " | Instruction: " << jumpInfo.insText
                       << " | Executed: " << std::dec << jumpInfo.count << " times\n"
                       << " | Targets: ";
            
            for (const auto& target : jumpInfo.targets) {
                OutputFile << "0x" << std::hex << target << " ";
            }
            
            OutputFile << "\n";
        }
        
        OutputFile.close();
    }
}

// Instrument instructions to track indirect jumps
VOID Instruction(INS ins, VOID* v) {
    if (IsIndirectJump(ins)) {
        ADDRINT insAddr = INS_Address(ins);
        if (insAddr >= textSectionBase && insAddr < textSectionHigh) {
            std::string* disassembly = new std::string(INS_Disassemble(ins));

            INS_InsertCall(ins, IPOINT_TAKEN_BRANCH, (AFUNPTR)TrackIndirectJump,
                           IARG_INST_PTR,     
                           IARG_CONTEXT,      
                           IARG_BRANCH_TARGET_ADDR, 
                           IARG_PTR, disassembly,  
                           IARG_END);
        }
    }
}

// Main function
int main(int argc, char* argv[]) {
    if (PIN_Init(argc, argv)) {
        std::cerr << "PIN initialization failed." << std::endl;
        return 1;
    }

    OutputFile.open("disassembly.log", std::ios::app);

    if (!OutputFile.is_open()) {
        std::cerr << "Failed to open the output file." << std::endl;
        return 1;
    }

    IMG_AddInstrumentFunction(ImageLoad, 0);
    INS_AddInstrumentFunction(Instruction, 0);
    PIN_AddFiniFunction(F
