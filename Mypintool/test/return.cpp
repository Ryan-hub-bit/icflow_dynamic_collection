#include <iostream>

// Example functions to be called
void func1() {
    std::cout << "In func1" << std::endl;
}

void func2() {
    std::cout << "In func2" << std::endl;
}

// Function that performs an indirect call and returns
void call_and_return(void (*func)()) {
    func(); // Call the function
    // Return to caller of `call_and_return` (this might be optimized to an indirect jump)
}

// Main function to test
int main() {
    void (*func_ptr)() = func1;
    call_and_return(func_ptr);

    func_ptr = func2;
    call_and_return(func_ptr);

    return 0;
}

