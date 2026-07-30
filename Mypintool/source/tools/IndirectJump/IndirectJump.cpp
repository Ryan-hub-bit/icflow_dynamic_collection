#include "pin.H"
#include <iostream>

void Instruction(INS ins, VOID *v) {
    std::cout << "Instruction: " << INS_Disassemble(ins) << std::endl;
}

void Fini(INT32 code, VOID *v) {
    std::cout << "Program Finished!" << std::endl;
}

int main(int argc, char *argv[]) {
    if (PIN_Init(argc, argv)) {
        std::cerr << "Error initializing PIN!" << std::endl;
        return 1;
    }

    INS_AddInstrumentFunction(Instruction, nullptr);
    PIN_AddFiniFunction(Fini, nullptr);

    PIN_StartProgram();
    return 0;
}

