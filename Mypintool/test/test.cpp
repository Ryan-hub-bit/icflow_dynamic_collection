#include <iostream>
#include<random>

// Define some functions to be called indirectly
void function1(int e) {
    std::cout << "function1 called" << std::endl;
    std::cout << e << std::endl;
}

void function2(int e) {
    std::cout << "function1 called" << std::endl;
    std::cout << e << std::endl;
    std::cout << "function2 called" << std::endl;
}

// Function that takes a function pointer and performs a tail call
__attribute__((noinline))
void tailCallFunction(void (*func)(int), int a ) {
    a= rand();
    int* b = new int(42); // Initialized with va
    int* c = b + 1; 
     *c=rand();
    func(a+*c);  // Tail call to the function pointer
}

int main() {
    // Set the function pointer to point to function1
    void (*funcPtr)(int) = function1;

    // Call tailCallFunction with the function pointer
    tailCallFunction(funcPtr, 2);

    // Change the function pointer to point to function2
    funcPtr = function2;

    // Call tailCallFunction with the function pointer again
    tailCallFunction(funcPtr,2);

    return 0;
}
