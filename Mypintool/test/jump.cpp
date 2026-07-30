#include <iostream>

void function1() {
    std::cout << "Case 1: Calling function1\n";
}

void function2() {
    std::cout << "Case 2: Calling function2\n";
}

void function3() {
    std::cout << "Case 3: Calling function3\n";
}

void jumpTableExample(int caseValue) {
    switch (caseValue) {
        case 1:
            function1();
            break;
        case 2:
            function2();
            break;
        case 3:
            function3();
            break;
        default:
            std::cout << "Default case\n";
            break;
    }
}

int main() {
    jumpTableExample(1);
    jumpTableExample(2);
    jumpTableExample(3);
    jumpTableExample(4);
    return 0;
}

