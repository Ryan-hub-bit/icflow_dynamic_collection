#include <iostream>
#include <cstdint>

// Function type for jump table
using JumpFunction = void (*)();

// Sample functions
void function1() {
    std::cout << "Function 1 called" << std::endl;
}

void function2() {
    std::cout << "Function 2 called" << std::endl;
}

void function3() {
    std::cout << "Function 3 called" << std::endl;
}

// Explicit indirect jump demonstration
void demonstrateIndirectJump() {
    // Array of function pointers (jump table)
    JumpFunction jumpTable[] = {
        function1,
        function2,
        function3
    };

    // Get function index (simulated)
    int index = 1;

    // Explicit indirect jump using inline assembly
    // This method is x86-specific and works with GCC/Clang
    #if defined(__GNUC__) && (defined(__x86_64__) || defined(__i386__))
        __asm__ volatile (
            "movl %0, %%eax\n\t"   // Move index to eax
            "movl %1, %%ebx\n\t"   // Move jump table base address to ebx
            "movl (%ebx,%%eax,4), %%eax\n\t"  // Load function address 
            "jmp *%%eax\n\t"       // Indirect jump
            :                      // No output
            : "r"(index), "r"(jumpTable)  // Input operands
            : "%eax", "%ebx"       // Clobbered registers
        );
    #else
        // Fallback method using function pointer
        jumpTable[index]();
    #endif
}

int main() {
    demonstrateIndirectJump();
    return 0;
}
