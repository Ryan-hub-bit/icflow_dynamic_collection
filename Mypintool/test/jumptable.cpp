#include <iostream>
#include <ctime>
#include <cstdlib>

void function1(int e) {
    std::cout << "function1 called: Value = " << e << std::endl;
}

void function2(int e) {
    std::cout << "function2 called: Value = " << e << std::endl;
}

void tailCallFunction(void (*func)(int), int a) {
    a = rand();
    int* b = new int[2];
    b[0] = 42;
    b[1] = rand();
    func(a + b[1]);
    delete[] b;
}

void jumpTableSwitch(int input) {
    // A simple switch statement suitable for jump table optimization
    switch (input) {
        case 0:
            std::cout << "Case 0: Performing operation A" << std::endl;
            break;
        case 1:
            std::cout << "Case 1: Calling function1" << std::endl;
            function1(10);
            break;
        case 2:
            std::cout << "Case 2: Calling function2" << std::endl;
            function2(20);
            break;
        case 3:
            std::cout << "Case 3: Using tailCallFunction" << std::endl;
            tailCallFunction(function1, 15);
            break;
        default:
            std::cout << "Default Case: Invalid input" << std::endl;
            break;
    }
}

int main() {
    srand(static_cast<unsigned int>(time(nullptr)));  // Seed random number generator

    int input = rand() % 5;  // Generate input from 0 to 4
    std::cout << "Input: " << input << std::endl;

    jumpTableSwitch(input);

    return 0;
}

