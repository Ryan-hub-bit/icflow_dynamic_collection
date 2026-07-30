#include <iostream>
#include <vector>
#include <functional>

// Function types to be used in the jump table
void func1() {
    std::cout << "Function 1 executed" << std::endl;
}

void func2() {
    std::cout << "Function 2 executed" << std::endl;
}

void func3() {
    std::cout << "Function 3 executed" << std::endl;
}

class JumpTable {
private:
    // Vector of function pointers
    std::vector<std::function<void()>> jumpTable;

public:
    // Constructor to populate the jump table
    JumpTable() {
        // Add functions to the jump table
        jumpTable.push_back(func1);
        jumpTable.push_back(func2);
        jumpTable.push_back(func3);
    }

    // Method to execute a function by index
    void executeFunction(size_t index) {
        // Check if the index is valid
        if (index < jumpTable.size()) {
            // Indirect jump using function pointer
            jumpTable[index]();
        } else {
            std::cout << "Invalid function index" << std::endl;
        }
    }

    // Method to add a new function to the jump table
    void addFunction(std::function<void()> func) {
        jumpTable.push_back(func);
    }
};

// Additional function to demonstrate extensibility
void func4() {
    std::cout << "Function 4 executed" << std::endl;
}

int main() {
    JumpTable jumpTable;

    // Demonstrate indirect jumps
    std::cout << "Executing functions via jump table:" << std::endl;
    jumpTable.executeFunction(0);  // Calls func1
    jumpTable.executeFunction(1);  // Calls func2
    jumpTable.executeFunction(2);  // Calls func3

    // Dynamically add a new function
    jumpTable.addFunction(func4);
    jumpTable.executeFunction(3);  // Calls func4

    return 0;
}
