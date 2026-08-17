#include <cstdlib>

static int increment(int value) { return value + 1; }
static int decrement(int value) { return value - 1; }

int main(int argc, char**) {
    int (*operation)(int) = argc > 1 ? decrement : increment;
    const int expected = argc > 1 ? 40 : 42;
    return operation(41) == expected ? EXIT_SUCCESS : EXIT_FAILURE;
}
