#include <iostream>
#include <random>
#include <ctime>

__attribute__((noinline))
void function1(int e) {
    std::cout << "function1 called" << std::endl;
    std::cout << "Value: " << e << std::endl;
}
__attribute__((noinline))
void function2(int e) {
    std::cout << "function2 called" << std::endl;
    std::cout << "Value: " << e << std::endl;
}

__attribute__((noinline))
void tailCallFunction(void (*func)(int), int a) {
    a = rand();
    int* b = new int[2];  // Allocate space for two integers
    b[0] = 42;
    b[1] = rand();
    func(a + b[1]);  // Tail call to the function pointer
    delete[] b;  // Free allocated memory
}

// Function with a complex switch-case
void complexSwitch(int input, void (*funcPtr)(int)) {
    switch (input) {
        case 1: {
            std::cout << "Case 1: Calling function1 via funcPtr" << std::endl;
            funcPtr(10);
            break;
        }
        case 2:
            std::cout << "Case 2: Generating random number" << std::endl;
            std::cout << "Random number: " << rand() % 100 << std::endl;
            break;
        case 3: {
            std::cout << "Case 3: Nested switch" << std::endl;
            int nestedInput = rand() % 3;
            switch (nestedInput) {
                case 0:
                    std::cout << "Nested Case 0: Performing addition" << std::endl;
                    std::cout << "5 + 3 = " << 5 + 3 << std::endl;
                    break;
                case 1:
                    std::cout << "Nested Case 1: Calling function2 directly" << std::endl;
                    function2(25);
                    break;
                case 2:
                    std::cout << "Nested Case 2: Using tailCallFunction" << std::endl;
                    tailCallFunction(funcPtr, 15);
                    break;
                default:
                    std::cout << "Nested Default Case" << std::endl;
                    break;
            }
            break;
        }
        case 4: {
            std::cout << "Case 4: Iterating with a loop" << std::endl;
            for (int i = 0; i < 5; ++i) {
                std::cout << "Loop iteration: " << i << std::endl;
            }
            break;
        }
        default:
            std::cout << "Default Case: No valid input provided" << std::endl;
            break;
    }
}

int main() {
    srand(time(nullptr));  // Seed the random number generator

    // Set the function pointer to point to function1
    void (*funcPtr)(int) = function1;

    // Call tailCallFunction with the function pointer
    tailCallFunction(funcPtr, 2);

    // Change the function pointer to point to function2
    funcPtr = function2;

    // Call tailCallFunction with the function pointer again
    tailCallFunction(funcPtr, 2);

    // Use the complex switch-case function
    std::cout << "\n--- Complex Switch Test ---" << std::endl;
    int userInput = rand() % 6;  // Randomly generate input from 0 to 5
    std::cout << "Input: " << userInput << std::endl;
    complexSwitch(userInput, funcPtr);

    return 0;
}

